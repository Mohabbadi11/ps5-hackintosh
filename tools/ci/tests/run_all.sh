#!/bin/bash
# Runs every test and the offline checks against the repo given as $1; exits 1 if anything fails.
HERE="$(cd "$(dirname "$0")" && pwd)"; REPO="$1"; failed=()
for t in "$HERE"/test_*.sh; do echo "=== $(basename "$t")"; bash "$t" "$REPO" || failed+=("$(basename "$t")"); done
echo "=== test_madt.py"; python3 -I "$HERE/test_madt.py" "$REPO" || failed+=(test_madt.py)
echo "=== check.sh"; bash "$HERE/check.sh" "$REPO" || failed+=(check.sh)
# the checker must itself fail on a broken file: a throwaway clone with one bad shell and one bad Python file
tmp=$(mktemp -d); git clone -q "$REPO" "$tmp/c" && printf 'if then\n' > "$tmp/c/tools/broken.sh" && printf 'def (:\n' > "$tmp/c/tools/broken.py"
if bash "$HERE/check.sh" "$tmp/c" >"$tmp/out" 2>&1; then echo "FAIL check.sh passed a broken tree"; failed+=(check.sh-self-test)
else echo "PASS check.sh exits 1 on a broken tree ($(grep -c '^FAIL' "$tmp/out") failures reported)"; fi
rm -rf "$tmp"
echo; if [ ${#failed[@]} -eq 0 ]; then echo "ALL PASSED"; else echo "FAILED: ${failed[*]}"; exit 1; fi
