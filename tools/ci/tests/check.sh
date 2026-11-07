#!/bin/bash
# Offline checks: bash -n on every shell script, py_compile on every Python file, no CR line endings. Exits 1 if any check fails.
cd "$1" || exit 1
fails=0
for f in $(git ls-files '*.sh') $(git ls-files --others --exclude-standard '*.sh') initramfs/init; do
    bash -n "$f" || { echo "FAIL bash -n $f"; fails=$((fails+1)); }
done
echo "bash -n: $(( $(git ls-files '*.sh' | wc -l) + $(git ls-files --others --exclude-standard '*.sh' | wc -l) + 1 )) files checked"
for f in $(git ls-files '*.py') $(git ls-files --others --exclude-standard '*.py'); do
    python3 -I -m py_compile "$f" || { echo "FAIL py_compile $f"; fails=$((fails+1)); }
done
echo "py_compile: $(( $(git ls-files '*.py' | wc -l) + $(git ls-files --others --exclude-standard '*.py' | wc -l) )) files checked"
find . -name __pycache__ -prune -exec rm -rf {} +
if crs=$(grep -lI $'\r' $(git ls-files) $(git ls-files --others --exclude-standard)); then echo "FAIL CR line endings in: $crs"; fails=$((fails+1)); else echo "no CR in any text file"; fi
echo "offline checks: $fails failure(s)"
[ "$fails" -eq 0 ]
