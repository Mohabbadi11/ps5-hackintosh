/*
 * PS5 Hackintosh — Payload loader
 *
 * Reads bzImage + initramfs from USB FAT32 volume and maps them into
 * physical memory via the kernel page-install syscore interface.
 */

#include <stdint.h>
#include <stddef.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <string.h>

#include "config.h"
#include "loader.h"
#include "offsets.h"

static void *map_file(const char *path, size_t *out_size, size_t max)
{
    struct stat st;
    int fd = open(path, O_RDONLY);
    if (fd < 0)
        return NULL;

    if (fstat(fd, &st) != 0 || (size_t)st.st_size > max) {
        close(fd);
        return NULL;
    }

    size_t sz = (st.st_size > 0) ? (size_t)st.st_size : max;
    void *buf = mmap(NULL, sz, PROT_READ | PROT_WRITE,
                     MAP_ANONYMOUS | MAP_SHARED, -1, 0);
    if (buf == MAP_FAILED) {
        close(fd);
        return NULL;
    }

    size_t total = 0;
    while (total < (size_t)st.st_size) {
        ssize_t n = read(fd, (uint8_t *)buf + total, st.st_size - total);
        if (n <= 0)
            break;
        total += n;
    }
    close(fd);

    *out_size = total;
    return buf;
}

static int read_cmdline(char *buf, size_t buflen)
{
    int fd = open("/mnt/usb" USB_CMDLINE_PATH, O_RDONLY);
    if (fd < 0) {
        strncpy(buf, DEFAULT_CMDLINE, buflen - 1);
        buf[buflen - 1] = '\0';
        return 0;
    }

    ssize_t n = read(fd, buf, buflen - 1);
    close(fd);
    if (n <= 0) {
        strncpy(buf, DEFAULT_CMDLINE, buflen - 1);
        buf[buflen - 1] = '\0';
    } else {
        buf[n] = '\0';
        /* strip trailing newline */
        while (n > 0 && (buf[n-1] == '\n' || buf[n-1] == '\r'))
            buf[--n] = '\0';
    }
    return 0;
}

static uint64_t vtophys_user(void *va)
{
    /* Use the kernel vtophys via the payload SDK syscall interface */
    typedef uint64_t (*vtophys_fn)(uint64_t);
    vtophys_fn fn = (vtophys_fn)KERN_VTOPHYS;
    return fn((uint64_t)va);
}

static int copy_to_kernel_cave(uint64_t dst_pa, void *src, size_t len)
{
    for (size_t off = 0; off < len; off += PAGE_SIZE) {
        size_t chunk = (len - off < PAGE_SIZE) ? (len - off) : PAGE_SIZE;
        uint64_t src_pa = vtophys_user((uint8_t *)src + off);
        if (install_page_syscore(dst_pa + off, src_pa, 0) != 0)
            return -1;
        (void)chunk;
    }
    return 0;
}

int fetch_hackintosh_payload(struct hackintosh_boot *boot)
{
    size_t bz_size = 0, initrd_size = 0;

    /* Map bzImage */
    void *bzimage = map_file("/mnt/usb" USB_BZIMAGE_PATH,
                             &bz_size, BZIMAGE_MAX_SIZE);
    if (!bzimage)
        return -1;

    /* Map initramfs */
    void *initrd = map_file("/mnt/usb" USB_INITRD_PATH,
                            &initrd_size, INITRD_MAX_SIZE);
    if (!initrd) {
        munmap(bzimage, bz_size);
        return -1;
    }

    /* Read cmdline */
    read_cmdline(boot->linux.cmdline, sizeof(boot->linux.cmdline));

    /* Copy bzImage to kernel cave */
    uint64_t cave_base = get_kernel_cave_base();
    boot->linux.bzimage_pa   = cave_base + PAGE_SIZE;
    boot->linux.bzimage_size = bz_size;

    if (copy_to_kernel_cave(boot->linux.bzimage_pa, bzimage, bz_size) != 0) {
        munmap(bzimage, bz_size);
        munmap(initrd, initrd_size);
        return -1;
    }

    /* Copy initrd to kernel cave (after bzImage, page-aligned) */
    boot->linux.initrd_pa   = boot->linux.bzimage_pa +
                              ALIGN_UP(bz_size, PAGE_SIZE);
    boot->linux.initrd_size = initrd_size;

    if (copy_to_kernel_cave(boot->linux.initrd_pa, initrd, initrd_size) != 0) {
        munmap(bzimage, bz_size);
        munmap(initrd, initrd_size);
        return -1;
    }

    /* Copy linux_info struct */
    struct linux_info *info = (struct linux_info *)mmap(NULL, PAGE_SIZE,
        PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_SHARED, -1, 0);
    if (info == MAP_FAILED)
        return -1;

    *info = boot->linux;
    install_page_syscore(cave_base, vtophys_user(info), 0);

    munmap(bzimage, bz_size);
    munmap(initrd, initrd_size);
    return 0;
}
