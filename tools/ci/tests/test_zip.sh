#!/bin/bash
# Tests for tools/ziputil.sh (zip_ok, kext_in_zip, fetch_zip) with made-up zips and local file:// "downloads"; no network.
REPO="$1"; source "$REPO/tools/ziputil.sh"
command -v unzip >/dev/null || { echo "SKIP: unzip not installed"; exit 2; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; failn=0
ok() { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; failn=$((failn+1)); }
python3 -I - "$W" <<'PY'
import sys, zipfile, os, plistlib
w = sys.argv[1]
def plist(exe): return plistlib.dumps({"CFBundleIdentifier": "as.vit9696." + (exe or "x"), **({"CFBundleExecutable": exe} if exe else {})})
def mk(name, files):
    with zipfile.ZipFile(f"{w}/{name}", "w", zipfile.ZIP_DEFLATED) as z:
        for n, data in files.items():
            z.writestr(zipfile.ZipInfo(n), data)
lilu = {"Lilu.kext/Contents/Info.plist": plist("Lilu"), "Lilu.kext/Contents/MacOS/Lilu": os.urandom(30000), "Lilu.kext.dSYM/x": b"d"}
mk("good.zip", lilu)
mk("nested.zip", {"Kexts/VirtualSMC.kext/Contents/Info.plist": plist("VirtualSMC"), "Kexts/VirtualSMC.kext/Contents/MacOS/VirtualSMC": b"v" * 100,
                  "Kexts/SMCProcessor.kext/Contents/Info.plist": plist("SMCProcessor"), "Kexts/SMCProcessor.kext/Contents/MacOS/SMCProcessor": b"s" * 100})
mk("nested_no_smcp.zip", {"Kexts/VirtualSMC.kext/Contents/Info.plist": plist("VirtualSMC"), "Kexts/VirtualSMC.kext/Contents/MacOS/VirtualSMC": b"v"})
mk("readme_only.zip", {"Lilu.kext/README": b"hello"})
mk("no_exe.zip", {"Lilu.kext/Contents/Info.plist": plist("Lilu")})
mk("exe_unnamed.zip", {"Lilu.kext/Contents/Info.plist": plist(None), "Lilu.kext/Contents/MacOS/Lilu": b"x"})
mk("exe_mismatch.zip", {"Lilu.kext/Contents/Info.plist": plist("Lilu"), "Lilu.kext/Contents/MacOS/Other": b"x"})
mk("bad_plist.zip", {"Lilu.kext/Contents/Info.plist": b"<<not a plist", "Lilu.kext/Contents/MacOS/Lilu": b"x"})
mk("plugin_only.zip", {"Other.kext/Contents/PlugIns/Lilu.kext/Contents/Info.plist": plist("Lilu"), "Other.kext/Contents/PlugIns/Lilu.kext/Contents/MacOS/Lilu": b"x",
                       "Lilu.kext/Contents/Info.plist": plist("Lilu")})
mk("traversal.zip", {**lilu, "../evil.sh": b"x"})
mk("traversal2.zip", {**lilu, "Lilu.kext/../../evil": b"x"})
mk("absolute.zip", {**lilu, "/etc/evil": b"x"})
mk("backslash.zip", {**lilu, r"..\evil": b"x"})
mk("wrong.zip", {"AMD Power Gadget.app/Contents/Info.plist": plist("AMD Power Gadget")})
mk("dsym_only.zip", {"Lilu.kext.dSYM/Contents/Info.plist": plist("Lilu")})
mk("oc.zip", {"X64/EFI/BOOT/BOOTx64.efi": b"b", "X64/EFI/OC/OpenCore.efi": b"o", "X64/EFI/OC/Drivers/OpenRuntime.efi": b"r"})
d = bytearray(open(f"{w}/good.zip", "rb").read())
d[300] ^= 0xFF                                               # a flipped byte in the compressed executable: CRC error
open(f"{w}/corrupt.zip", "wb").write(d)
open(f"{w}/cut.zip", "wb").write(bytes(d[:len(d) // 2]))   # incomplete download
open(f"{w}/html.zip", "wb").write(b"<html>rate limit exceeded</html>")
PY
yes_() { zip_ok "$W/$1" "${@:3}" && ok "$2" || bad "$2"; }
no_()  { zip_ok "$W/$1" "${@:3}" && bad "$2" || ok "$2"; }
yes_ good.zip            "complete kext (Info.plist + the executable it names) accepted" kext:Lilu
yes_ nested.zip          "kexts in a Kexts/ folder accepted, both VirtualSMC and SMCProcessor" kext:VirtualSMC kext:SMCProcessor
no_  nested_no_smcp.zip  "VirtualSMC zip without SMCProcessor rejected (every check required)" kext:VirtualSMC kext:SMCProcessor
no_  readme_only.zip     "Lilu.kext/ holding only a README rejected" kext:Lilu
no_  no_exe.zip          "Info.plist without the executable rejected" kext:Lilu
no_  exe_unnamed.zip     "Info.plist with no CFBundleExecutable rejected" kext:Lilu
no_  exe_mismatch.zip    "executable with another name than the plist says rejected" kext:Lilu
no_  bad_plist.zip       "unreadable Info.plist rejected" kext:Lilu
no_  plugin_only.zip     "a complete Lilu.kext only inside another kext's PlugIns does not count (outer one is incomplete)" kext:Lilu
no_  traversal.zip       "entry ../evil.sh rejected" kext:Lilu
no_  traversal2.zip      "entry Lilu.kext/../../evil rejected" kext:Lilu
no_  absolute.zip        "entry with an absolute path rejected" kext:Lilu
no_  backslash.zip       "entry with a backslash (..\evil) rejected" kext:Lilu
no_  corrupt.zip         "corrupt zip (CRC error) rejected" kext:Lilu
no_  cut.zip             "incomplete zip rejected" kext:Lilu
no_  html.zip            "HTML error page saved as .zip rejected" kext:Lilu
no_  wrong.zip           "zip without the kext rejected (the AMD.Power.Gadget case)" kext:Lilu
no_  dsym_only.zip       "Lilu.kext.dSYM alone does not count as Lilu.kext" kext:Lilu
no_  missing.zip         "missing file rejected" kext:Lilu
yes_ oc.zip              "OpenCore zip with the boot files accepted (regex checks)" '^X64/EFI/BOOT/BOOTx64\.efi$' '^X64/EFI/OC/OpenCore\.efi$'
no_  oc.zip              "OpenCore zip without OpenHfsPlus.efi rejected" '^X64/EFI/OC/OpenCore\.efi$' '/OpenHfsPlus\.efi$'

mkdir -p "$W/dl"
fetch_zip "file://$W/good.zip" "$W/dl/Lilu.zip" kext:Lilu >/dev/null && cmp -s "$W/good.zip" "$W/dl/Lilu.zip" && [ ! -e "$W/dl/Lilu.zip.part" ] \
    && ok "fresh download validated and moved into the cache" || bad "fresh download"
out=$(fetch_zip "file://$W/nonexistent.zip" "$W/dl/Lilu.zip" kext:Lilu 2>&1) && grep -q "verificado" <<<"$out" && ok "good cached zip reused without downloading" || bad "cache reuse ($out)"
cp "$W/readme_only.zip" "$W/dl/Lilu.zip"
out=$(fetch_zip "file://$W/good.zip" "$W/dl/Lilu.zip" kext:Lilu 2>&1) && cmp -s "$W/good.zip" "$W/dl/Lilu.zip" && grep -q "dañado" <<<"$out" \
    && ok "cached zip with an incomplete kext detected and downloaded again" || bad "bad cache ($out)"
for b in cut readme_only traversal nonexistent; do
    rm -f "$W/dl/Lilu.zip"
    fetch_zip "file://$W/$b.zip" "$W/dl/Lilu.zip" kext:Lilu >/dev/null 2>&1 && bad "download $b accepted" \
        || { [ ! -e "$W/dl/Lilu.zip" ] && [ ! -e "$W/dl/Lilu.zip.part" ] && ok "download '$b' refused, nothing left in the cache"; } || bad "download $b leftovers"
done
echo "ZIP tests: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
