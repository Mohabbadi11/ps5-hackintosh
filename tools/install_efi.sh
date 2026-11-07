#!/bin/bash
# Runs on the console (clean_run.sh, ktty_run.sh and tripwire_run.sh copy it to /root): replaces ESP/EFI with the EFI folder in TAR.
# Extract into ESP/EFI.new and check it, move the old folder to ESP/EFI.bak, move the new one in; if that last move fails, put the old
# folder back. EFI.bak is kept until the next install (the way back by hand: mv EFI.bak EFI).
# The one moment without an ESP/EFI is between those two renames (a power cut there): the next run then finds EFI.bak without EFI and
# puts EFI.bak back before doing anything else, so the only good copy is never deleted.
#   Usage: install_efi.sh TAR [ESP]      (ESP defaults to /boot/efi)
set -euo pipefail
TAR="${1:?usage: install_efi.sh TAR [ESP]}"
ESP="${2:-/boot/efi}"
NEW="$ESP/EFI.new"
BAK="$ESP/EFI.bak"
fail() { echo "install_efi: $*" >&2; exit 1; }

[ -s "$TAR" ] || fail "no EFI archive at $TAR"
[ -d "$ESP" ] || fail "no ESP directory $ESP"

# an earlier run stopped between the two renames: EFI.bak is the last EFI that was in place, put it back first
if [ ! -e "$ESP/EFI" ] && [ -d "$BAK" ]; then
    mv "$BAK" "$ESP/EFI" || fail "$ESP/EFI is missing and $BAK could not be moved back: restore it by hand (mv $BAK $ESP/EFI)"
    echo "install_efi: $ESP/EFI was missing (an earlier install was interrupted): restored it from $BAK" >&2
fi

# the old and the new folder are both on the ESP for a moment: make sure it has room for the new one
need_kb=$(( $(du -k "$TAR" | cut -f1) + 1024 ))
free_kb=$(df -Pk "$ESP" | awk 'NR == 2 {print $4}')
[ "$free_kb" -ge "$need_kb" ] || fail "only ${free_kb} KiB free on $ESP, the new EFI needs about ${need_kb} KiB: nothing changed"

rm -rf "$NEW"
mkdir "$NEW"
if ! tar -C "$NEW" -xf "$TAR"; then
    rm -rf "$NEW"
    fail "could not extract $TAR: the current EFI folder is untouched"
fi
for f in EFI/BOOT/BOOTx64.efi EFI/OC/OpenCore.efi EFI/OC/config.plist; do
    [ -s "$NEW/$f" ] || { rm -rf "$NEW"; fail "the archive has no $f: the current EFI folder is untouched"; }
done
if command -v python3 >/dev/null 2>&1; then
    python3 -I -c 'import plistlib, sys; plistlib.load(open(sys.argv[1], "rb"))' "$NEW/EFI/OC/config.plist" \
        || { rm -rf "$NEW"; fail "EFI/OC/config.plist in the archive is not a valid plist: the current EFI folder is untouched"; }
fi

if [ -d "$ESP/EFI" ]; then
    rm -rf "$BAK"                      # an older backup; the folder in place now becomes the new one
    mv "$ESP/EFI" "$BAK" || { rm -rf "$NEW"; fail "could not move the current EFI folder aside: it is untouched"; }
fi
if ! mv "$NEW/EFI" "$ESP/EFI"; then
    rm -rf "$ESP/EFI"
    if [ -d "$BAK" ]; then
        mv "$BAK" "$ESP/EFI" || fail "the new EFI could not be put in place AND the old one could not be restored: it is at $BAK, move it back by hand"
        fail "the new EFI could not be put in place: the old one is restored"
    fi
    fail "the new EFI could not be put in place (there was no old one)"
fi
rmdir "$NEW" 2>/dev/null || rm -rf "$NEW"
sync
echo "install_efi: new EFI in place at $ESP/EFI (the previous one is at $BAK)"
