# shellcheck shell=bash
# Zip downloads that are checked before they are trusted (sourced by fetch_opencore.sh).

# zip_ok FILE REGEX...: the archive passes unzip's integrity test and, for each REGEX, at least one entry name matches it
zip_ok() {
    local f="$1"; shift
    [ -s "$f" ] || return 1
    unzip -tqq "$f" >/dev/null 2>&1 || return 1
    local names re
    names="$(unzip -Z1 "$f" 2>/dev/null)" || return 1
    for re in "$@"; do
        grep -qE -- "$re" <<<"$names" || return 1
    done
}

# fetch_zip URL OUT REGEX...: keep OUT only if it is a good zip with the expected entries. A cached OUT is checked too and fetched
# again when it fails. The download goes to OUT.part and is moved into place only after the check.
fetch_zip() {
    local url="$1" out="$2"; shift 2
    if [ -f "$out" ]; then
        if zip_ok "$out" "$@"; then echo "  [✓] $(basename "$out") ya descargado (verificado)"; return 0; fi
        echo "  [!] $(basename "$out") en caché está dañado o incompleto: se descarga otra vez"
        rm -f "$out"
    fi
    rm -f "$out.part"
    if ! curl -fsSL -o "$out.part" "$url"; then
        rm -f "$out.part"; echo "  [!] fallo al descargar $url" >&2; return 1
    fi
    if ! zip_ok "$out.part" "$@"; then
        rm -f "$out.part"; echo "  [!] $(basename "$out"): el zip descargado está dañado o no contiene $*" >&2; return 1
    fi
    mv "$out.part" "$out"
    echo "  [✓] $(basename "$out") ($(du -h "$out" | cut -f1))"
}
