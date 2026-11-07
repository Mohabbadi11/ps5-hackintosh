#!/bin/bash
# Failure-path tests for tools/install_efi.sh on a fake ESP (a temp folder); no console involved.
REPO="$1"; INST="$REPO/tools/install_efi.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; failn=0
ok() { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; failn=$((failn+1)); }
PLIST='<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict/></plist>'
efi_dir() {  # efi_dir DIR MARKER [incomplete]: a bootable-looking EFI folder (or one missing OpenCore.efi)
    mkdir -p "$1/BOOT" "$1/OC"; echo boot > "$1/BOOT/BOOTx64.efi"; echo "$PLIST" > "$1/OC/config.plist"; echo "$2" > "$1/OC/marker"
    [ "${3:-}" = incomplete ] || echo oc > "$1/OC/OpenCore.efi"
}
mk_old() { rm -rf "$W/esp"; mkdir -p "$W/esp"; efi_dir "$W/esp/EFI" old; }
mk_tar() {  # name [skip-file] [badplist]
    rm -rf "$W/src"; efi_dir "$W/src/EFI" new
    [ "${3:-}" = badplist ] && echo "not a plist" > "$W/src/EFI/OC/config.plist"
    [ -n "${2:-}" ] && rm -f "$W/src/$2"
    tar -C "$W/src" -cf "$W/$1.tar" EFI
}
marker() { cat "$1/OC/marker" 2>/dev/null; }
old_intact() { [ "$(marker "$W/esp/EFI")" = old ] && [ ! -e "$W/esp/EFI.new" ]; }
fake_mv_fail() {  # a stand-in mv that fails only for the final move of the new folder into place
    mkdir -p "$W/fakebin"; rm -f "$W/fakebin/df"
    printf '#!/bin/bash\ncase "$1" in *EFI.new/EFI) echo "mv: simulated failure" >&2; exit 1;; esac\nexec /bin/mv "$@"\n' > "$W/fakebin/mv"; chmod +x "$W/fakebin/mv"
}

mk_old; mk_tar good; head -c 3000 "$W/good.tar" > "$W/cut.tar"; printf 'garbage' >> "$W/cut.tar"; head -c 100 /dev/urandom > "$W/junk.tar"
mk_tar nooc EFI/OC/OpenCore.efi; mk_tar badplist "" badplist; mk_tar good

# --- normal and failed installs
mk_old; bash "$INST" "$W/good.tar" "$W/esp" >/dev/null 2>&1 && [ "$(marker "$W/esp/EFI")" = new ] && [ "$(marker "$W/esp/EFI.bak")" = old ] && [ ! -e "$W/esp/EFI.new" ] \
    && ok "good archive: new EFI in place, old one kept as EFI.bak" || bad "good archive"
mk_old; out=$(bash "$INST" "$W/cut.tar" "$W/esp" 2>&1); rc=$?
[ $rc -ne 0 ] && old_intact && grep -q "could not extract\|has no" <<<"$out" && ok "cut-short archive: refused, error shown, old EFI untouched" || bad "cut-short archive ($out)"
mk_old; out=$(bash "$INST" "$W/junk.tar" "$W/esp" 2>&1); rc=$?
[ $rc -ne 0 ] && old_intact && ok "random bytes: refused, old EFI untouched (tar said: $(grep -m1 tar <<<"$out" | cut -c1-60))" || bad "random bytes"
mk_old; bash "$INST" "$W/nooc.tar" "$W/esp" >/dev/null 2>&1; [ $? -ne 0 ] && old_intact && ok "archive without OpenCore.efi: refused, old EFI untouched" || bad "missing OpenCore.efi"
mk_old; bash "$INST" "$W/badplist.tar" "$W/esp" >/dev/null 2>&1; [ $? -ne 0 ] && old_intact && ok "broken config.plist: refused, old EFI untouched" || bad "broken plist"
fake_mv_fail; mk_old; out=$(PATH="$W/fakebin:$PATH" bash "$INST" "$W/good.tar" "$W/esp" 2>&1); rc=$?
[ $rc -ne 0 ] && [ "$(marker "$W/esp/EFI")" = old ] && grep -q "is restored" <<<"$out" && ok "swap fails: old EFI restored" || bad "rollback ($rc $out)"
rm -f "$W/fakebin/mv"; printf '#!/bin/bash\necho "Filesystem 1024-blocks Used Available Capacity Mounted on"; echo "fake 100 90 10 90%% /x"\n' > "$W/fakebin/df"; chmod +x "$W/fakebin/df"
mk_old; out=$(PATH="$W/fakebin:$PATH" bash "$INST" "$W/good.tar" "$W/esp" 2>&1); rc=$?
[ $rc -ne 0 ] && old_intact && grep -q "free" <<<"$out" && ok "ESP too full: refused before touching anything" || bad "space check ($out)"
rm -f "$W/fakebin/df"
mk_old; bash "$INST" "$W/none.tar" "$W/esp" >/dev/null 2>&1; [ $? -ne 0 ] && old_intact && ok "missing archive: refused" || bad "missing archive"

# --- interrupted install: EFI missing, EFI.bak holds the last good folder
interrupted() { rm -rf "$W/esp"; mkdir -p "$W/esp"; efi_dir "$W/esp/EFI.bak" old; }
interrupted; out=$(bash "$INST" "$W/good.tar" "$W/esp" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(marker "$W/esp/EFI")" = new ] && [ "$(marker "$W/esp/EFI.bak")" = old ] && grep -q "restored it from" <<<"$out" \
    && ok "EFI missing + EFI.bak, good archive: backup restored first, then kept as EFI.bak; new EFI in place" || bad "interrupted + good ($rc $out)"
interrupted; out=$(bash "$INST" "$W/junk.tar" "$W/esp" 2>&1); rc=$?
[ $rc -ne 0 ] && old_intact && grep -q "restored it from" <<<"$out" && ok "EFI missing + EFI.bak, bad archive: backup restored as EFI, not deleted" || bad "interrupted + bad ($rc $out)"
fake_mv_fail; interrupted; out=$(PATH="$W/fakebin:$PATH" bash "$INST" "$W/good.tar" "$W/esp" 2>&1); rc=$?
[ $rc -ne 0 ] && [ "$(marker "$W/esp/EFI")" = old ] && ok "EFI missing + EFI.bak, then the swap fails: the backup ends up back as EFI" || bad "interrupted + swap failure ($rc $out)"
rm -f "$W/fakebin/mv"

# --- EFI present but incomplete (the case from the third review)
broken_good_bak() { rm -rf "$W/esp"; mkdir -p "$W/esp"; efi_dir "$W/esp/EFI" half incomplete; efi_dir "$W/esp/EFI.bak" old; }
broken_good_bak; out=$(bash "$INST" "$W/good.tar" "$W/esp" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(marker "$W/esp/EFI")" = new ] && [ "$(marker "$W/esp/EFI.bak")" = old ] && [ "$(marker "$W/esp/EFI.broken")" = half ] && grep -q "was incomplete" <<<"$out" \
    && ok "incomplete EFI + good EFI.bak, good archive: the good backup survives as EFI.bak, the incomplete one is EFI.broken" || bad "broken + good bak + good ($rc $out)"
broken_good_bak; out=$(bash "$INST" "$W/junk.tar" "$W/esp" 2>&1); rc=$?
[ $rc -ne 0 ] && old_intact && [ "$(marker "$W/esp/EFI.broken")" = half ] && ok "incomplete EFI + good EFI.bak, bad archive: the good backup is put back as EFI" || bad "broken + good bak + bad ($rc $out)"
fake_mv_fail; broken_good_bak; out=$(PATH="$W/fakebin:$PATH" bash "$INST" "$W/good.tar" "$W/esp" 2>&1); rc=$?
[ $rc -ne 0 ] && [ "$(marker "$W/esp/EFI")" = old ] && ok "incomplete EFI + good EFI.bak, swap fails: EFI ends up as the good backup" || bad "broken + good bak + swap failure ($rc $out)"
rm -f "$W/fakebin/mv"
rm -rf "$W/esp"; mkdir -p "$W/esp"; efi_dir "$W/esp/EFI" half incomplete; efi_dir "$W/esp/EFI.bak" bakhalf incomplete
out=$(bash "$INST" "$W/good.tar" "$W/esp" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(marker "$W/esp/EFI")" = new ] && [ "$(marker "$W/esp/EFI.bak")" = bakhalf ] && [ "$(marker "$W/esp/EFI.broken")" = half ] \
    && ok "incomplete EFI + incomplete EFI.bak: EFI.bak left as it was, incomplete EFI kept as EFI.broken, new EFI in place" || bad "both incomplete ($rc $out)"
rm -rf "$W/esp"; mkdir -p "$W/esp"; efi_dir "$W/esp/EFI" half incomplete
out=$(bash "$INST" "$W/good.tar" "$W/esp" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(marker "$W/esp/EFI")" = new ] && [ ! -e "$W/esp/EFI.bak" ] && [ "$(marker "$W/esp/EFI.broken")" = half ] \
    && ok "incomplete EFI, no backup: never becomes EFI.bak (kept as EFI.broken)" || bad "broken no bak ($rc $out)"
rm -rf "$W/esp"; mkdir -p "$W/esp/EFI/OC"; echo x > "$W/esp/EFI/OC/marker"; efi_dir "$W/esp/EFI.bak" old; echo "not a plist" > "$W/esp/EFI/OC/config.plist"
out=$(bash "$INST" "$W/good.tar" "$W/esp" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(marker "$W/esp/EFI.bak")" = old ] && ok "EFI with an unreadable config.plist counts as incomplete: the good EFI.bak survives" || bad "bad plist in place ($rc $out)"

# --- backup rotation
mk_old; bash "$INST" "$W/good.tar" "$W/esp" >/dev/null 2>&1; echo newer > "$W/esp/EFI/OC/marker"
bash "$INST" "$W/good.tar" "$W/esp" >/dev/null 2>&1 && [ "$(marker "$W/esp/EFI.bak")" = newer ] && ok "next install: EFI.bak becomes the good folder that was in place" || bad "backup rotation"
rm -rf "$W/esp"; mkdir -p "$W/esp"; out=$(bash "$INST" "$W/good.tar" "$W/esp" 2>&1); rc=$?
[ $rc -eq 0 ] && [ "$(marker "$W/esp/EFI")" = new ] && ok "empty ESP: new EFI installed" || bad "empty ESP ($rc $out)"
echo "EFI tests: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
