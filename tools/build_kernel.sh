#!/bin/bash
#
# PS5 Hackintosh — Compilar kernel Linux con KVM para PS5
#
# Descarga el kernel Linux, aplica los patches de ps5-linux,
# habilita KVM/VFIO, y compila bzImage.
#
# Requiere Docker (compilación cruzada x86_64 desde macOS ARM).
#
# Uso: ./tools/build_kernel.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD="$PROJECT_DIR/build"

KERNEL_VER="7.1.7"
KERNEL_MAJOR="${KERNEL_VER%%.*}"
PATCHES_REPO="https://github.com/ps5-linux/ps5-linux-patches"

mkdir -p "$BUILD/kernel"

echo "╔══════════════════════════════════════════════════╗"
echo "║  PS5 Hackintosh — Compilar kernel $KERNEL_VER         ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""

# ── Verificar Docker ──────────────────────────────────
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker no está corriendo."
    exit 1
fi

# ── Descargar patches (repo completo — incluye firmware) ─
PATCH_DIR="$BUILD/kernel/ps5-linux-patches"
if [ ! -d "$PATCH_DIR/.git" ]; then
    echo "[1/4] Clonando ps5-linux-patches (incluye firmware)..."
    rm -rf "$PATCH_DIR"
    git clone --depth 1 "$PATCHES_REPO" "$PATCH_DIR"
    echo "  Patches + firmware descargados"
else
    echo "[1/4] Patches ya descargados"
fi

# ── Crear config con KVM ─────────────────────────────
echo "[2/4] Preparando config con KVM/VFIO..."
KVM_CONFIG="$BUILD/kernel/kvm-additions.config"
cat > "$KVM_CONFIG" << 'KVMEOF'
# KVM / hardware virtualization
CONFIG_VIRTUALIZATION=y
CONFIG_KVM=y
CONFIG_KVM_AMD=y
CONFIG_KVM_AMD_SEV=n

# VFIO / GPU passthrough
CONFIG_VFIO=y
CONFIG_VFIO_PCI=y
CONFIG_VFIO_IOMMU_TYPE1=y
CONFIG_VFIO_MDEV=n
CONFIG_IRQ_BYPASS_MANAGER=y

# IOMMU
CONFIG_AMD_IOMMU=y
CONFIG_AMD_IOMMU_V2=y
CONFIG_IOMMU_DEFAULT_PASSTHROUGH=y

# Hugepages
CONFIG_HUGETLBFS=y
CONFIG_HUGETLB_PAGE=y
CONFIG_TRANSPARENT_HUGEPAGE=y

# Virtio (for QEMU guests)
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_DRM_VIRTIO_GPU=y

# TUN/TAP for networking
CONFIG_TUN=y
CONFIG_BRIDGE=y

# Loop device for disk images
CONFIG_BLK_DEV_LOOP=y

# cpio / initramfs
CONFIG_BLK_DEV_INITRD=y
CONFIG_BLK_DEV_RAM=y
CONFIG_BLK_DEV_RAM_SIZE=65536

# Filesystem support for USB
CONFIG_VFAT_FS=y
CONFIG_EXFAT_FS=y
CONFIG_EXT4_FS=y
CONFIG_NLS_CODEPAGE_437=y
CONFIG_NLS_ISO8859_1=y
CONFIG_NLS_UTF8=y
KVMEOF

echo "  KVM/VFIO config preparada"

# ── Compilar con Docker ───────────────────────────────
echo "[3/4] Compilando kernel (esto tarda ~15-30 min)..."
echo "  Kernel: $KERNEL_VER"
echo "  Compilando en Docker x86_64..."

docker run --rm --platform linux/amd64 \
    -v "$BUILD/kernel:/build" \
    -v "$PATCH_DIR:/build/ps5-linux-patches:ro" \
    -v "$KVM_CONFIG:/build/kvm-additions.config:ro" \
    -w /build \
    alpine:3.20 sh -c "
    set -e

    apk add --no-cache gcc musl-dev make flex bison bc perl \
        elfutils-dev openssl-dev linux-headers diffutils findutils \
        xz coreutils bash patch git >/dev/null 2>&1

    KERNEL_VER=$KERNEL_VER
    KERNEL_MAJOR=$KERNEL_MAJOR

    # Descargar kernel si no existe
    if [ ! -d linux-\${KERNEL_VER} ]; then
        echo '  Descargando kernel...'
        wget -q https://cdn.kernel.org/pub/linux/kernel/v\${KERNEL_MAJOR}.x/linux-\${KERNEL_VER}.tar.xz
        echo '  Extrayendo...'
        tar xf linux-\${KERNEL_VER}.tar.xz
        rm linux-\${KERNEL_VER}.tar.xz
    fi

    cd linux-\${KERNEL_VER}

    # Aplicar patches de PS5
    if [ ! -f .ps5_patched ]; then
        echo '  Aplicando patches PS5...'
        patch -p1 < /build/ps5-linux-patches/linux.patch || true
        touch .ps5_patched
    fi

    # Copiar config base de PS5
    cp /build/ps5-linux-patches/.config .config

    # Añadir opciones KVM/VFIO
    echo '  Habilitando KVM/VFIO...'
    while IFS= read -r line; do
        case \"\$line\" in
            '#'*|'') continue ;;
            CONFIG_*=*)
                key=\${line%%=*}
                if grep -q \"^\${key}=\" .config 2>/dev/null; then
                    sed -i \"s|^\${key}=.*|\${line}|\" .config
                elif grep -q \"^# \${key} is not set\" .config 2>/dev/null; then
                    sed -i \"s|^# \${key} is not set|\${line}|\" .config
                else
                    echo \"\$line\" >> .config
                fi
                ;;
        esac
    done < /build/kvm-additions.config

    # Resolver dependencias
    make olddefconfig

    echo '  Compilando bzImage...'
    make -j\$(nproc) bzImage 2>&1

    # Copiar resultado
    cp arch/x86/boot/bzImage /build/bzImage
    echo ''
    echo \"  bzImage listo: \$(du -h /build/bzImage | cut -f1)\"
"

# ── Copiar al build principal ─────────────────────────
echo "[4/4] Copiando bzImage..."
cp "$BUILD/kernel/bzImage" "$BUILD/bzImage"
ls -lh "$BUILD/bzImage"

echo ""
echo "═══════════════════════════════════════════════"
echo "Kernel compilado: $BUILD/bzImage"
echo "  Version: $KERNEL_VER + ps5-linux-patches + KVM/VFIO"
echo "═══════════════════════════════════════════════"
