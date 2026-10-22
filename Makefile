# PS5 Hackintosh — Build system
#
# Uses ps5-linux-loader (upstream) for the exploit chain.
# Our project adds: custom cmdline (KVM/VFIO), initramfs (macOS boot),
# OpenCore config, and USB preparation tools.
#
# The loader reads bzImage + initrd.img + cmdline.txt from USB — we just
# provide the right files, and the upstream exploit does the rest.

-include .env

PS5_HOST     ?= 192.168.1.91
FTP_PORT     ?= 2121
BUILD        := build
LOADER_DIR   := third_party/ps5-linux-loader
INITRAMFS_D  := $(BUILD)/initramfs_root

.PHONY: all clean loader initramfs usb deploy acpi

all: loader initramfs

# ── Upstream loader (builds the ELF that goes to the PS5) ──────────
loader:
	$(MAKE) -C $(LOADER_DIR)
	@mkdir -p $(BUILD)/bin
	cp $(LOADER_DIR)/bin/ps5-linux-loader.elf $(BUILD)/bin/
	@echo "Loader built: $(BUILD)/bin/ps5-linux-loader.elf"

# ── Custom initramfs for macOS boot ────────────────────────────────
# Contains: busybox, QEMU (static), KVM modules, boot scripts, OpenCore
initramfs: $(BUILD)/initrd.img
$(BUILD)/initrd.img: initramfs/init initramfs/scripts/boot-macos.sh
	@echo "Building Hackintosh initramfs..."
	@mkdir -p $(INITRAMFS_D)/{bin,sbin,dev,proc,sys,mnt/usb,mnt/macos,etc,tmp,scripts,lib/modules}

	# Core scripts
	cp initramfs/init $(INITRAMFS_D)/init
	chmod +x $(INITRAMFS_D)/init
	cp initramfs/scripts/*.sh $(INITRAMFS_D)/scripts/
	chmod +x $(INITRAMFS_D)/scripts/*.sh
	cp initramfs/etc/* $(INITRAMFS_D)/etc/ 2>/dev/null || true

	# Check for required binaries
	@if [ ! -f $(BUILD)/bin/busybox ]; then \
		echo ""; \
		echo "WARNING: $(BUILD)/bin/busybox not found."; \
		echo "Run: ./tools/fetch_binaries.sh"; \
		echo ""; \
	else \
		cp $(BUILD)/bin/busybox $(INITRAMFS_D)/bin/busybox; \
		chmod +x $(INITRAMFS_D)/bin/busybox; \
		cd $(INITRAMFS_D)/bin && for cmd in sh ls cat mount umount mkdir cp mv rm \
			modprobe insmod lsmod mknod sleep echo clear grep sed awk \
			dmesg ifconfig ip route; do \
			ln -sf busybox $$cmd; \
		done; \
		cd $(INITRAMFS_D)/sbin && for cmd in modprobe insmod; do \
			ln -sf ../bin/busybox $$cmd; \
		done; \
	fi

	@if [ ! -f $(BUILD)/bin/qemu-system-x86_64 ]; then \
		echo ""; \
		echo "WARNING: $(BUILD)/bin/qemu-system-x86_64 not found."; \
		echo "Run: ./tools/fetch_binaries.sh"; \
		echo ""; \
	else \
		cp $(BUILD)/bin/qemu-system-x86_64 $(INITRAMFS_D)/bin/; \
		chmod +x $(INITRAMFS_D)/bin/qemu-system-x86_64; \
	fi

	# Build cpio archive
	cd $(INITRAMFS_D) && find . | cpio -o -H newc 2>/dev/null | gzip > $(CURDIR)/$(BUILD)/initrd.img
	@echo "Initramfs built: $(BUILD)/initrd.img ($(shell du -h $(BUILD)/initrd.img 2>/dev/null | cut -f1))"

# ── Compile ACPI tables ────────────────────────────────────────────
acpi:
	@command -v iasl >/dev/null 2>&1 || { echo "iasl not found. Install: brew install acpica"; exit 1; }
	@mkdir -p $(BUILD)/acpi
	cd opencore/ACPI && for dsl in *.dsl; do \
		iasl -tc "$$dsl" && mv "$${dsl%.dsl}.aml" $(CURDIR)/$(BUILD)/acpi/; \
	done
	@echo "ACPI tables compiled in $(BUILD)/acpi/"

# ── Prepare USB drive contents ─────────────────────────────────────
usb: initramfs acpi
	@mkdir -p $(BUILD)/usb/macos/EFI/OC/{ACPI,Drivers,Kexts}
	@mkdir -p $(BUILD)/usb/macos/EFI/BOOT

	# Kernel + initramfs (bzImage must be provided separately)
	@if [ -f $(BUILD)/bzImage ]; then cp $(BUILD)/bzImage $(BUILD)/usb/; fi
	cp $(BUILD)/initrd.img $(BUILD)/usb/initrd.img

	# Cmdline
	cp usb/cmdline.txt $(BUILD)/usb/cmdline.txt
	cp usb/vram.txt $(BUILD)/usb/vram.txt 2>/dev/null || true

	# OpenCore config + ACPI
	cp opencore/config.plist $(BUILD)/usb/macos/EFI/OC/config.plist
	cp $(BUILD)/acpi/*.aml $(BUILD)/usb/macos/EFI/OC/ACPI/ 2>/dev/null || true

	@echo ""
	@echo "USB contents ready in $(BUILD)/usb/"
	@echo "Copy to your FAT32/exFAT USB drive."

# ── Deploy loader to PS5 ──────────────────────────────────────────
deploy: loader
	@echo "Sending loader to $(PS5_HOST):9021..."
	socat -t 99999999 - TCP:$(PS5_HOST):9021 < $(BUILD)/bin/ps5-linux-loader.elf
	@echo "Sent. PS5 will enter rest mode, then boot into macOS on wake."

# ── Clean ──────────────────────────────────────────────────────────
clean:
	rm -rf $(BUILD)
	$(MAKE) -C $(LOADER_DIR) clean 2>/dev/null || true
