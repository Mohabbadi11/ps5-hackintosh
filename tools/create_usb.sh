#!/bin/bash
#
# PS5 Hackintosh — Preparar USB de arranque (3 particiones)
#
# Wizard interactivo que lista discos externos, te deja elegir,
# y crea el USB con la estructura necesaria.
#
# Estructura del USB:
#   Partición 1 (FAT32, ~500MB): bzImage, initrd.img, cmdline.txt
#   Partición 2 (ext4, ~1.2GB):  rootfs Alpine con QEMU
#   Partición 3 (exFAT, resto):  macos/ con OpenCore.img, OVMF, macOS.img
#
# Uso: ./tools/create_usb.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"

echo ""
echo "╔══════════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Preparación del USB           ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Verificar artefactos ─────────────────────────────
echo "Verificando artefactos..."
echo ""
MISSING=""
ALL_OK=true
for f in bzImage initrd.img OpenCore.img OVMF_CODE.fd OVMF_VARS.fd rootfs.img macOS.img; do
    if [ -f "$BUILD/$f" ]; then
        printf "  %-20s %s\n" "$f" "$(du -h "$BUILD/$f" | cut -f1)"
    else
        printf "  %-20s FALTA\n" "$f"
        MISSING="$MISSING $f"
        ALL_OK=false
    fi
done
echo ""

if [ "$ALL_OK" = false ]; then
    echo "ERROR: Faltan artefactos:$MISSING"
    echo ""
    echo "Ejecuta primero:"
    echo "  ./tools/build_kernel.sh      # bzImage"
    echo "  make initramfs               # initrd.img"
    echo "  ./tools/fetch_opencore.sh    # kexts + drivers"
    echo "  ./tools/build_opencore_img.sh # OpenCore.img"
    echo "  ./tools/create_rootfs.sh     # rootfs.img"
    echo "  ./tools/create_macos_img.sh  # macOS.img"
    exit 1
fi

# ── Listar discos externos ───────────────────────────
echo "Buscando discos externos..."
echo ""

DISKS=()
DISK_INFO=()

while IFS= read -r line; do
    disk=$(echo "$line" | awk '{print $1}')
    [ -z "$disk" ] && continue

    # Saltar si no es disco block
    [ ! -b "$disk" ] && continue

    # Obtener info del disco
    info=$(diskutil info "$disk" 2>/dev/null) || continue

    # Solo discos externos/removibles
    is_internal=$(echo "$info" | grep -i "Internal:" | awk '{print $NF}')
    is_removable=$(echo "$info" | grep -i "Removable Media:" | awk '{print $NF}')
    protocol=$(echo "$info" | grep -i "Protocol:" | awk '{print $NF}')

    # Saltar discos internos
    if [ "$is_internal" = "Yes" ] && [ "$is_removable" != "Yes" ]; then
        continue
    fi

    # Saltar disk images (DMG montados, etc.)
    if [ "$protocol" = "Disk" ] && echo "$info" | grep -qi "image"; then
        continue
    fi

    disk_size=$(echo "$info" | grep "Disk Size:" | sed 's/.*:[ ]*//' | sed 's/ (.*//')
    disk_name=$(echo "$info" | grep "Media Name:" | sed 's/.*:[ ]*//')
    [ -z "$disk_name" ] && disk_name="(sin nombre)"

    DISKS+=("$disk")
    DISK_INFO+=("$(printf "%-12s  %-10s  %s" "$disk" "$disk_size" "$disk_name")")

done < <(diskutil list 2>/dev/null | grep "^/dev/disk" | awk '{print $1}')

if [ ${#DISKS[@]} -eq 0 ]; then
    echo "  No se encontraron discos externos."
    echo ""
    echo "  Conecta un USB de al menos 64 GB y vuelve a ejecutar."
    exit 1
fi

echo "  Discos externos encontrados:"
echo ""
printf "  %-4s %-12s  %-10s  %s\n" "#" "Dispositivo" "Tamaño" "Nombre"
echo "  ─────────────────────────────────────────────────"

for i in "${!DISK_INFO[@]}"; do
    printf "  %-4s %s\n" "[$((i+1))]" "${DISK_INFO[$i]}"
done
echo ""

# ── Seleccionar disco ────────────────────────────────
read -p "  Selecciona el disco (1-${#DISKS[@]}) o 'q' para salir: " CHOICE

if [ "$CHOICE" = "q" ] || [ "$CHOICE" = "Q" ]; then
    echo "  Cancelado."
    exit 0
fi

if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || [ "$CHOICE" -lt 1 ] || [ "$CHOICE" -gt ${#DISKS[@]} ]; then
    echo "  Opción inválida."
    exit 1
fi

DISK="${DISKS[$((CHOICE-1))]}"

# ── Mostrar info detallada y confirmar ───────────────
echo ""
echo "  ┌─────────────────────────────────────────────┐"
echo "  │  DISCO SELECCIONADO                         │"
echo "  └─────────────────────────────────────────────┘"
diskutil info "$DISK" | grep -E "Device Node:|Media Name:|Disk Size:|Removable|Protocol:" | sed 's/^/  /'
echo ""

# Mostrar particiones actuales
echo "  Particiones actuales:"
diskutil list "$DISK" 2>/dev/null | tail -n+2 | sed 's/^/  /'
echo ""

echo "  ⚠️  ATENCIÓN: Se BORRARÁN TODOS los datos de este disco."
echo "  Se crearán 3 particiones para PS5 Hackintosh."
echo ""
read -p "  ¿Estás seguro? Escribe 'BORRAR' para confirmar: " CONFIRM

if [ "$CONFIRM" != "BORRAR" ]; then
    echo "  Cancelado. (Escribe exactamente 'BORRAR' para confirmar)"
    exit 0
fi

echo ""

# ── Particionar ──────────────────────────────────────
echo "[1/6] Desmontando disco..."
diskutil unmountDisk "$DISK" 2>/dev/null || true

echo "[2/6] Creando tabla de particiones GPT..."
echo "  Part 1: FAT32  500 MB  (boot: bzImage + initrd)"
echo "  Part 2: Free  1.2 GB   (rootfs ext4: Alpine + QEMU)"
echo "  Part 3: exFAT  resto   (macos: OpenCore + macOS.img)"
diskutil partitionDisk "$DISK" GPT \
    FAT32 PS5BOOT 500MB \
    "Free Space" ROOTFS 1200MB \
    ExFAT PS5MACOS R

echo ""
echo "[3/6] Copiando boot files a PS5BOOT..."
BOOT_VOL="/Volumes/PS5BOOT"
if [ -d "$BOOT_VOL" ]; then
    cp "$BUILD/bzImage" "$BOOT_VOL/"
    cp "$BUILD/initrd.img" "$BOOT_VOL/"
    cp "$PROJECT_DIR/usb/cmdline.txt" "$BOOT_VOL/"
    [ -f "$PROJECT_DIR/usb/vram.txt" ] && cp "$PROJECT_DIR/usb/vram.txt" "$BOOT_VOL/"
    echo "  bzImage + initrd.img + cmdline.txt copiados"
else
    echo "  Error: $BOOT_VOL no montado"
    exit 1
fi

echo "[4/6] Escribiendo rootfs ext4..."
# diskutil deja la part 2 como "Free Space" — necesitamos encontrarla
# Es la segunda partición del disco
PART2="${DISK}s2"
if [ -e "$PART2" ]; then
    echo "  Escribiendo rootfs.img en $PART2 (necesita sudo)..."
    sudo dd if="$BUILD/rootfs.img" of="$PART2" bs=4M 2>&1
    echo "  rootfs escrito en $PART2"
else
    echo "  Advertencia: $PART2 no encontrado"
    echo "  Escribe manualmente: sudo dd if=build/rootfs.img of=${DISK}s2 bs=4M"
fi

echo "[5/6] Copiando archivos macOS a PS5MACOS..."
MACOS_VOL="/Volumes/PS5MACOS"
# Esperar a que se monte
for i in $(seq 1 5); do
    [ -d "$MACOS_VOL" ] && break
    sleep 1
done

if [ -d "$MACOS_VOL" ]; then
    mkdir -p "$MACOS_VOL/macos"
    echo "  Copiando OpenCore.img..."
    cp "$BUILD/OpenCore.img" "$MACOS_VOL/macos/"
    echo "  Copiando OVMF_CODE.fd..."
    cp "$BUILD/OVMF_CODE.fd" "$MACOS_VOL/macos/"
    echo "  Copiando OVMF_VARS.fd..."
    cp "$BUILD/OVMF_VARS.fd" "$MACOS_VOL/macos/"
    echo "  Copiando macOS.img ($(du -h "$BUILD/macOS.img" | cut -f1) — esto tarda un rato)..."
    cp "$BUILD/macOS.img" "$MACOS_VOL/macos/"
    echo "  Todo copiado a PS5MACOS"
else
    echo "  Error: $MACOS_VOL no montado"
    exit 1
fi

echo "[6/6] Sincronizando y expulsando..."
sync
diskutil unmountDisk "$DISK" 2>/dev/null || true

echo ""
echo "═══════════════════════════════════════════════════"
echo ""
echo "  ✓ USB LISTO"
echo ""
echo "  Partición 1 (FAT32  PS5BOOT):  bzImage + initrd + cmdline"
echo "  Partición 2 (ext4):            rootfs Alpine + QEMU + ds-mouse"
echo "  Partición 3 (exFAT  PS5MACOS): OpenCore + OVMF + macOS.img"
echo ""
echo "  Siguiente paso:"
echo "    1. Conecta el USB a la PS5"
echo "    2. Activa el jailbreak en la PS5"
echo "    3. Ejecuta: ./tools/launch_hackintosh.sh"
echo ""
echo "═══════════════════════════════════════════════════"
