# PS5 Hackintosh Loader
# Boots macOS on PlayStation 5 via modified Linux loader chain
# Copyright (C) 2026 - GPL-3.0-or-later

-include .env

PS5_PAYLOAD_SDK ?= /Users/rodrigo/.local/ps5-payload-sdk
include $(PS5_PAYLOAD_SDK)/toolchain/prospero.mk

# ── Toolchain ──────────────────────────────────────────────────────
HOSTCC       := clang
HOSTLD       := ld.lld
NASM         := nasm

# ── Build paths ────────────────────────────────────────────────────
BUILD        := build
BIN          := $(BUILD)/bin
OBJ          := $(BUILD)/obj
SHELLCODE    := $(BUILD)/shellcode
INITRAMFS_D  := $(BUILD)/initramfs
PKG_OUT      := $(BUILD)/pkg

# ── Firmware target (13.60) ────────────────────────────────────────
FW_VERSION   := 0x1360
PS5_HOST     ?= 192.168.1.91
FTP_PORT     ?= 2121

# ── Source files ───────────────────────────────────────────────────
SRC          := $(wildcard src/*.c)
OBJ_FILES    := $(SRC:src/%.c=$(OBJ)/%.o)

SHELLCODE_HV_SRC  := $(wildcard shellcode/hv/*.c)
SHELLCODE_KRN_SRC := $(wildcard shellcode/kernel/*.c)
SHELLCODE_AP_SRC  := shellcode/ap/entry.S shellcode/ap/main.c

# ── Compiler flags ─────────────────────────────────────────────────
CFLAGS := -std=c23 -Wall -Wextra -Werror \
          -Iinclude -Ishellcode/hv -Ishellcode/kernel \
          -DFW_VERSION=$(FW_VERSION) \
          -O2 -fno-stack-protector

SCFLAGS := -std=c23 -Wall -ffreestanding -fno-stack-protector \
           -fno-builtin -nostdlib -O2 -fPIC \
           -Iinclude -DFW_VERSION=$(FW_VERSION)

LDFLAGS := -nostdlib

# ── Targets ────────────────────────────────────────────────────────
.PHONY: all clean deploy initramfs pkg

all: $(BIN)/ps5-hackintosh.elf

# ── Shellcode blobs → C headers ────────────────────────────────────
$(SHELLCODE)/shellcode_hv.bin: $(SHELLCODE_HV_SRC) shellcode/hv/linker.ld
	@mkdir -p $(@D)
	$(HOSTCC) $(SCFLAGS) -c shellcode/hv/main.c -o $(SHELLCODE)/hv_main.o
	$(HOSTLD) -T shellcode/hv/linker.ld -o $@ $(SHELLCODE)/hv_main.o

$(SHELLCODE)/shellcode_kernel.bin: $(SHELLCODE_KRN_SRC) shellcode/kernel/linker.ld
	@mkdir -p $(@D)
	$(HOSTCC) $(SCFLAGS) -c shellcode/kernel/main.c -o $(SHELLCODE)/krn_main.o
	$(HOSTLD) -T shellcode/kernel/linker.ld -o $@ $(SHELLCODE)/krn_main.o

$(SHELLCODE)/shellcode_ap.bin: $(SHELLCODE_AP_SRC) shellcode/ap/linker.ld
	@mkdir -p $(@D)
	$(NASM) -f elf64 shellcode/ap/entry.S -o $(SHELLCODE)/ap_entry.o
	$(HOSTCC) $(SCFLAGS) -c shellcode/ap/main.c -o $(SHELLCODE)/ap_main.o
	$(HOSTLD) -T shellcode/ap/linker.ld -o $@ $(SHELLCODE)/ap_entry.o $(SHELLCODE)/ap_main.o

include/shellcode_hv.h: $(SHELLCODE)/shellcode_hv.bin
	xxd -i $< > $@

include/shellcode_kernel.h: $(SHELLCODE)/shellcode_kernel.bin
	xxd -i $< > $@

include/shellcode_ap.h: $(SHELLCODE)/shellcode_ap.bin
	xxd -i $< > $@

SHELLCODE_HEADERS := include/shellcode_hv.h include/shellcode_kernel.h include/shellcode_ap.h

# ── Main ELF ───────────────────────────────────────────────────────
$(OBJ)/%.o: src/%.c $(SHELLCODE_HEADERS)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -c $< -o $@

$(BIN)/ps5-hackintosh.elf: $(OBJ_FILES)
	@mkdir -p $(@D)
	$(CC) $(CFLAGS) -o $@ $^

# ── Initramfs ──────────────────────────────────────────────────────
initramfs: $(BUILD)/initramfs.cpio.gz
$(BUILD)/initramfs.cpio.gz: initramfs/init initramfs/scripts/boot-macos.sh
	@mkdir -p $(INITRAMFS_D)/{bin,sbin,dev,proc,sys,mnt/usb,mnt/macos,etc,tmp,scripts}
	cp initramfs/init $(INITRAMFS_D)/init
	chmod +x $(INITRAMFS_D)/init
	cp initramfs/scripts/*.sh $(INITRAMFS_D)/scripts/
	chmod +x $(INITRAMFS_D)/scripts/*.sh
	cp initramfs/etc/* $(INITRAMFS_D)/etc/ 2>/dev/null || true
	cd $(INITRAMFS_D) && find . | cpio -o -H newc | gzip > ../initramfs.cpio.gz

# ── PKG (fPKG for PS5) ────────────────────────────────────────────
pkg: $(BIN)/ps5-hackintosh.elf
	@mkdir -p $(PKG_OUT)/sce_sys
	cp $(BIN)/ps5-hackintosh.elf $(PKG_OUT)/eboot.bin
	cp sce_sys/param.json $(PKG_OUT)/sce_sys/
	cp sce_sys/icon0.png $(PKG_OUT)/sce_sys/ 2>/dev/null || true
	@echo "PKG contents ready in $(PKG_OUT)/"
	@echo "Use prospero-pkg or PkgTool to create the .pkg file"

# ── Deploy ─────────────────────────────────────────────────────────
deploy: $(BIN)/ps5-hackintosh.elf
	socat -t 99999999 - TCP:$(PS5_HOST):9021 < $<

deploy-ftp: $(BIN)/ps5-hackintosh.elf
	curl -T $< ftp://$(PS5_HOST):$(FTP_PORT)/data/hackintosh/eboot.bin

# ── Clean ──────────────────────────────────────────────────────────
clean:
	rm -rf $(BUILD) include/shellcode_*.h
