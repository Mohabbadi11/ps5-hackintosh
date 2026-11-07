#!/bin/bash
# tools/install_macos_qemu.sh refuses bad input before it downloads or launches anything (curl and qemu are stand-ins that record a call),
# and tools/create_macos_img.sh prints the command with the version it made. Nothing is downloaded, nothing is launched.
REPO="$1"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; failn=0
ok() { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; failn=$((failn+1)); }
mkdir -p "$W/r/tools" "$W/r/build" "$W/bin"; cp "$REPO/tools/install_macos_qemu.sh" "$W/r/tools/"
for t in curl qemu-system-x86_64 qemu-img; do printf '#!/bin/bash\necho "%s $*" >> "$CALLS"\n' "$t" > "$W/bin/$t"; done; chmod +x "$W/bin/"*
touch "$W/r/build/"{macOS.img,OVMF_CODE.fd,OVMF_VARS.fd,OpenCore-OSX-KVM.qcow2}
run() { rm -f "$W/calls"; (cd "$W/r" && CALLS="$W/calls" PATH="$W/bin:$PATH" bash tools/install_macos_qemu.sh "$@" >"$W/out" 2>&1); }

run bigsur; rc=$?
[ $rc -ne 0 ] && [ ! -e "$W/calls" ] && grep -q "no soportada" "$W/out" && ok "unsupported version rejected before any download or launch" || bad "unsupported ($rc $(cat "$W/out"))"
run sequoia; rc=$?
[ $rc -ne 0 ] && [ ! -e "$W/calls" ] && grep -q "create_macos_img.sh sequoia" "$W/out" && ok "missing sequoia recovery: stops, says which command makes it, QEMU not started" || bad "missing recovery ($rc $(cat "$W/out"))"
touch "$W/r/build/macOS-recovery-monterey.img"
run sequoia; rc=$?
[ $rc -ne 0 ] && [ ! -e "$W/calls" ] && ok "a Monterey recovery is not used for sequoia" || bad "cross-version ($rc)"
run; rc=$?
[ $rc -eq 0 ] && grep -q "macOS-recovery-monterey.img" "$W/calls" && ok "default monterey with its recovery: QEMU gets macOS-recovery-monterey.img" || bad "monterey launch ($rc $(cat "$W/calls" 2>/dev/null))"
rm "$W/r/build/macOS-recovery-monterey.img"
NO_RECOVERY=1 run; rc=$?
[ $rc -eq 0 ] && grep -q qemu "$W/calls" && ! grep -q "Recovery" "$W/calls" && ok "NO_RECOVERY=1 boots the installed disk without a recovery drive" || bad "NO_RECOVERY ($rc)"
rm "$W/r/build/OpenCore-OSX-KVM.qcow2"; printf '#!/bin/bash\necho "curl $*" >> "$CALLS"; exit 22\n' > "$W/bin/curl"; touch "$W/r/build/macOS-recovery-monterey.img"
run; rc=$?
[ $rc -ne 0 ] && [ ! -e "$W/r/build/OpenCore-OSX-KVM.qcow2" ] && [ ! -e "$W/r/build/OpenCore-OSX-KVM.qcow2.part" ] && ! grep -q qemu-system "$W/calls" \
    && ok "failed OpenCore qcow2 download: stops, nothing cached, QEMU not started" || bad "qcow2 download failure ($rc)"
grep -q 'install_macos_qemu.sh $VERSION' "$REPO/tools/create_macos_img.sh" && ok "create_macos_img.sh prints install_macos_qemu.sh with its version" || bad "printed command"
echo "installer tests: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
