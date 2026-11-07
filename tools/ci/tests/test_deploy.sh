#!/bin/bash
# Runs copies of tools/clean_run.sh, tools/ktty_run.sh and tools/tripwire_run.sh with stand-ins for ssh/scp and for the heavy build steps,
# to check what reaches scp (the step that sends files to the console). Nothing talks to a console.
REPO="$1"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; failn=0
ok() { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; failn=$((failn+1)); }
setup() {
    rm -rf "$W/r" "$W/log"; mkdir -p "$W/r/tools" "$W/r/bringup/tools" "$W/r/uefi" "$W/r/build/ext" "$W/r/build/bringup" "$W/r/opencore/ACPI/sony" "$W/bin"
    for f in clean_run.sh ktty_run.sh tripwire_run.sh stage1.sh lib.sh carveout.py install_efi.sh; do cp "$REPO/tools/$f" "$W/r/tools/"; done
    echo "PS5_LINUX_HOST=192.0.2.1" > "$W/r/.env"; touch "$W/r/opencore/ACPI/sony/APIC.bin" "$W/r/bringup/tools/"{patch_tripwire.py,run_stage.sh,kms_linear.py}
    printf 'import os\nos.makedirs("build/baremetal-efi/EFI", exist_ok=True)\nopen("build/efi-carve", "w").write(os.environ.get("CARVE_BASE", "unset"))\nprint("efi built")\n' > "$W/r/tools/make_baremetal_efi.py"
    printf 'import sys\nopen("build/welcome.raw","w").write("w")\n' > "$W/r/tools/make_welcome.py"
    printf 'import sys, os\nopen(sys.argv[2], "w").write("bundle for " + os.environ["CARVE_BASE"])\n' > "$W/r/uefi/mkbundle.py"
    printf '#!/bin/bash\necho "chain from $1" > build/bringup/chainV5.bzImage\n' > "$W/r/bringup/build.sh"; chmod +x "$W/r/bringup/build.sh"
    mkdir -p "$W/r/build/edk2/Build/UefiPayloadPkgX64"; touch "$W/r/build/edk2/Build/UefiPayloadPkgX64/UniversalPayload.elf"
    echo "kernel 6.1.0-ps5" > "$W/r/build/ext/vmlinuz-6.1.0-ps5"
    echo "STALE chain" > "$W/r/build/bringup/chainV5.bzImage"; echo "STALE bundle" > "$W/r/build/ps5-upl.bundle"
    cat > "$W/bin/ssh" <<'S'
#!/bin/bash
all="$*"; for a in "$@"; do last="$a"; done
case "$all" in
  *"uname -r") echo 6.1.0-ps5;;
  *"cat /proc/iomem") printf '100000000-43fffffff : System RAM\n440000000-46fffffff : Reserved\n';;
  *" true") exit 1;;                     # the console "went to UEFI": ends the wait loop
  *) echo "REMOTE: $last" | head -1 >> "$LOG";;
esac
S
    printf '#!/bin/bash\necho "SCP $*" >> "$LOG"\nfor f in "$@"; do case "$f" in *:*) ;; -*) ;; *) echo "  $f: $(head -c 40 "$f")" >> "$LOG";; esac; done\n' > "$W/bin/scp"
    printf '#!/bin/bash\n' > "$W/bin/sleep"
    chmod +x "$W/bin/"*
}
run() { (cd "$W/r" && LOG="$W/log" PATH="$W/bin:$PATH" bash "tools/$@" >"$W/out" 2>&1); }
nothing_sent() { [ ! -e "$W/log" ]; }
for s in clean_run.sh ktty_run.sh "tripwire_run.sh _tsc_init"; do
    n=${s%% *}
    setup; run $s; rc=$?
    if [ $rc -eq 0 ] && grep -q "chainV5.bzImage: chain from build/ext/vmlinuz-6.1.0-ps5" "$W/log" && grep -q "ps5-upl.bundle: bundle for 0x440000000" "$W/log" \
       && [ "$(cat "$W/r/build/efi-carve")" = 0x440000000 ] && ! grep -q STALE "$W/log" && grep -q "tools/install_efi.sh" "$W/log" \
       && grep -q "run_stage.sh" "$W/log" && grep -q "REMOTE: bash /root/install_efi.sh" "$W/log" && ! grep -q "rm -rf /boot/efi" "$W/log"; then
        ok "$n normal run: EFI, chain and bundle all for carve-out 0x440000000 and kernel 6.1.0-ps5; EFI installed through install_efi.sh"
    else bad "$n normal run (rc $rc): $(cat "$W/out" "$W/log" 2>/dev/null | head -20)"; fi

    setup; rm "$W/r/build/ext/vmlinuz-6.1.0-ps5"; echo old > "$W/r/build/ext/vmlinuz-5.15.0-old"; run $s; rc=$?
    [ $rc -ne 0 ] && nothing_sent && grep -q "missing build/ext/vmlinuz-6.1.0-ps5" "$W/out" && ok "$n: running kernel's vmlinuz missing (only another one there): stops, nothing sent" || bad "$n missing vmlinuz ($(cat "$W/out" "$W/log" 2>/dev/null|head -5))"

    setup; printf '#!/bin/bash\nexit 1\n' > "$W/r/bringup/build.sh"; run $s; rc=$?
    [ $rc -ne 0 ] && nothing_sent && ok "$n: stage-1 build fails: stops, the old chain is not sent" || bad "$n build failure"

    setup; printf '#!/bin/bash\ntrue\n' > "$W/r/bringup/build.sh"; run $s; rc=$?
    [ $rc -ne 0 ] && nothing_sent && grep -q "did not produce build/bringup/chainV5" "$W/out" && ok "$n: build makes no image: stops (the stale one was deleted first)" || bad "$n no image"

    setup; rm "$W/r/build/edk2/Build/UefiPayloadPkgX64/UniversalPayload.elf"; run $s; rc=$?
    [ $rc -ne 0 ] && nothing_sent && grep -q "missing build/edk2" "$W/out" && ok "$n: payload ELF missing: stops, the old bundle is not sent" || bad "$n missing ELF"

    setup; printf 'import sys\nsys.exit(1)\n' > "$W/r/uefi/mkbundle.py"; run $s; rc=$?
    [ $rc -ne 0 ] && nothing_sent && [ ! -e "$W/r/build/ps5-upl.bundle" ] && ok "$n: bundle build fails: stops, the old bundle was deleted and is not sent" || bad "$n mkbundle failure ($(cat "$W/out"))"

    setup; printf 'import sys\n' > "$W/r/uefi/mkbundle.py"; run $s; rc=$?
    [ $rc -ne 0 ] && nothing_sent && grep -q "did not produce build/ps5-upl.bundle" "$W/out" && ok "$n: bundle build writes nothing: stops" || bad "$n mkbundle no output"

    setup; printf '#!/bin/bash\ncase "$*" in *install_efi*) echo "REMOTE-FAIL" >> "$LOG"; exit 1;; *"uname -r") echo 6.1.0-ps5;; *iomem) printf "440000000-46fffffff : Reserved\\n";; *) exit 1;; esac\n' > "$W/bin/ssh"
    run $s; rc=$?
    [ $rc -ne 0 ] && grep -q REMOTE-FAIL "$W/log" && ok "$n: EFI install fails on the console: the deploy stops with an error" || bad "$n install failure ($rc)"
done
setup; run tripwire_run.sh; rc=$?
[ $rc -ne 0 ] && nothing_sent && grep -q "usage: tools/tripwire_run.sh" "$W/out" && ok "tripwire_run.sh without a symbol: usage, nothing built or sent" || bad "tripwire usage ($(cat "$W/out"))"
echo "deploy tests: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
