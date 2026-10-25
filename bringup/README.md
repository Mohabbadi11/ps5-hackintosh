# Bring-up without UART: crash-kexec stage 1

The PS5 has no usable serial port, and the display is dead until Linux/amdgpu starts it. These tools let us run our own
bare-metal code on the console and read the result back, without re-jailbreaking between attempts.

## Idea

1. `ps5-linux-loader` boots the stock Arch kernel with `crashkernel=400M` on its command line (`/boot/efi/cmdline.txt`).
2. A helper puts a linear 2560x1440 framebuffer on screen (`tools/kms_linear.py`, stop sway first).
3. A fake kernel (`stub.c` spliced in front of the real bzImage by `mkchain.py`) is loaded as the *crash* kernel
   with `kexec_file_load` (syscall 320, flags ON_CRASH|NO_INITRAMFS = 6) and `echo c > /proc/sysrq-trigger` runs it.
   Because a crash does not shut devices down, the GPU keeps scanning the framebuffer.
4. The stub (64-bit, paged, interrupts off) records marks/text at physical 0x300000000, draws on the framebuffer
   (phys 0x46a000000 = VRAM carve-out 0x450000000 + VRAM offset 0x1a000000) and finally jumps to the real kernel
   2 MiB later, so Linux comes back (1 CPU, no amdgpu) and the marks can be read over SSH (`tools/readmarks.py`,
   `tools/readlog.py`).

Only one crash-kexec per jailbreak boot works (chained crashes reset the console).

## Findings that shape the design

* Unthrottled posted writes through the GPU's MM_INDEX/MM_DATA window reset the console; a read every 1 KiB fixes it.
* The scanout buffer is ordinary system RAM: no GPU window is needed, the CPU writes it directly (map it uncached).
* The 2 MiB stub must fix `boot_params.hdr.init_size` (stage 1 subtracts 2 MiB) before jumping to the real kernel.

## Build

```bash
bringup/build.sh /path/to/vmlinuz     # -> build/bringup/chainV{0,1,2e,3,4}.bzImage
```
