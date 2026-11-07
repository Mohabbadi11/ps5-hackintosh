#!/bin/bash
# LLVM lookup: tools/llvm.sh (shell), tools/toolpaths.py (Python) and the Makefile's LLVM_CONFIG, all asserted.
REPO="$1"; source "$REPO/tools/llvm.sh"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
pass=0; failn=0
ok() { echo "PASS $1"; pass=$((pass+1)); }
bad() { echo "FAIL $1"; failn=$((failn+1)); }
mkdir -p "$W/llvm" "$W/noclang" "$W/noexec"
for t in clang ld.lld llvm-objcopy; do printf '#!/bin/sh\n' > "$W/llvm/$t"; chmod +x "$W/llvm/$t"; printf '#!/bin/sh\n' > "$W/noexec/$t"; done
for t in ld.lld llvm-objcopy; do printf '#!/bin/sh\n' > "$W/noclang/$t"; chmod +x "$W/noclang/$t"; done
chmod +x "$W/noexec/clang" "$W/noexec/ld.lld"          # llvm-objcopy there is not executable

r=$(LLVM_BIN="$W/llvm" llvm_bin) && [ "$r" = "$W/llvm" ] && ok "shell: LLVM_BIN with the three tools is used" || bad "shell LLVM_BIN"
for d in nothing noclang noexec; do
    out=$(LLVM_BIN="$W/$d" llvm_bin 2>&1) && bad "shell accepted $d" || { grep -q "no LLVM" <<<"$out" && ok "shell: LLVM_BIN '$d' rejected with a clear error"; } || bad "shell $d message"
done
out=$(LLVM_BIN="$W/nothing" bash -c 'set -euo pipefail; source "$1/tools/llvm.sh"; L="$(llvm_bin)"; echo WENT-ON' _ "$REPO" 2>&1); rc=$?
[ $rc -ne 0 ] && ! grep -q WENT-ON <<<"$out" && ok "shell: a set -e build script stops at L=\$(llvm_bin)" || bad "set -e ($rc $out)"

py() { LLVM_BIN="$1" python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1] + "/tools"); import toolpaths; print(toolpaths.llvm_bin())' "$REPO" 2>&1; }
r=$(py "$W/llvm") && [ "$r" = "$W/llvm" ] && ok "python: LLVM_BIN with the three tools is used" || bad "python LLVM_BIN ($r)"
for d in nothing noclang noexec; do
    out=$(py "$W/$d") && bad "python accepted $d ($out)" || { grep -q "no LLVM" <<<"$out" && ok "python: LLVM_BIN '$d' rejected, same rule as the shell helper"; } || bad "python $d message ($out)"
done

cd "$REPO"
mk() { env "$@" make -s --no-print-directory --eval 'pv: ; @echo $(LLVM_CONFIG)' pv; }
want_default=/opt/homebrew/opt/llvm@18/bin/llvm-config                 # neither Homebrew prefix exists on this Linux: the documented default
[ "$(mk -u LLVM_BIN -u LLVM_CONFIG)" = "$want_default" ] && ok "Makefile: no Homebrew llvm here -> $want_default" || bad "Makefile default: $(mk -u LLVM_BIN -u LLVM_CONFIG)"
[ "$(mk -u LLVM_CONFIG LLVM_BIN=/x)" = /x/llvm-config ] && ok "Makefile: LLVM_BIN=/x -> /x/llvm-config" || bad "Makefile LLVM_BIN"
[ "$(mk -u LLVM_BIN LLVM_CONFIG=/y/llvm-config)" = /y/llvm-config ] && ok "Makefile: LLVM_CONFIG set by the user wins" || bad "Makefile LLVM_CONFIG"
[ "$(mk -u LLVM_BIN -u LLVM_CONFIG LLVM_BIN=/x LLVM_CONFIG=/y/llvm-config)" = /y/llvm-config ] && ok "Makefile: LLVM_CONFIG wins over LLVM_BIN" || bad "Makefile both"
echo "LLVM tests: $pass passed, $failn failed"
[ "$failn" -eq 0 ]
