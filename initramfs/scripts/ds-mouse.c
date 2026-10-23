/*
 * ds-mouse — DualSense to mouse/keyboard mapper for PS5 Hackintosh
 *
 * Reads DualSense evdev input, creates virtual mouse + keyboard via uinput.
 * Runs on the Linux host before QEMU; virtual devices are passed to macOS.
 *
 * Mapping:
 *   Left stick  -> Mouse movement
 *   Right stick -> Scroll
 *   Cross (X)   -> Left click
 *   Circle      -> Right click
 *   Triangle    -> Enter
 *   Square      -> Space
 *   D-pad       -> Arrow keys
 *   L1          -> Escape
 *   R1          -> Tab
 *   L3          -> Middle click
 *   R3          -> Backspace
 *   Options     -> Cmd (Meta)
 *   Share       -> Alt
 *   Touchpad    -> Left click
 *
 * Writes created evdev paths to /tmp/ds-mouse.env for boot-macos.sh
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <signal.h>
#include <errno.h>
#include <linux/input.h>
#include <linux/uinput.h>
#include <sys/select.h>
#include <sys/ioctl.h>

#define DS_VENDOR  0x054c
#define DS_PRODUCT_DS  0x0ce6
#define DS_PRODUCT_DSE 0x0df2

#define DEADZONE    15
#define MOUSE_SPEED 8
#define SCROLL_SPEED 3

static volatile int running = 1;
static void on_signal(int s) { (void)s; running = 0; }

static void emit(int fd, int type, int code, int val) {
    struct input_event ev = {0};
    ev.type = type;
    ev.code = code;
    ev.value = val;
    write(fd, &ev, sizeof(ev));
}

static void emit_sync(int fd) {
    emit(fd, EV_SYN, SYN_REPORT, 0);
}

static int find_dualsense(char *path, size_t len) {
    DIR *dir = opendir("/dev/input");
    if (!dir) return -1;

    struct dirent *e;
    while ((e = readdir(dir))) {
        if (strncmp(e->d_name, "event", 5) != 0) continue;

        char p[256];
        snprintf(p, sizeof(p), "/dev/input/%s", e->d_name);
        int fd = open(p, O_RDONLY);
        if (fd < 0) continue;

        struct input_id id;
        if (ioctl(fd, EVIOCGID, &id) == 0 &&
            id.vendor == DS_VENDOR &&
            (id.product == DS_PRODUCT_DS || id.product == DS_PRODUCT_DSE)) {
            unsigned long absbits[(ABS_MAX / 8) + 1];
            memset(absbits, 0, sizeof(absbits));
            ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits);
            if (absbits[0] & (1 << ABS_X)) {
                close(fd);
                snprintf(path, len, "%s", p);
                closedir(dir);
                return 0;
            }
        }
        close(fd);
    }
    closedir(dir);
    return -1;
}

static int find_uinput_evdev(const char *name, char *path, size_t len) {
    DIR *dir = opendir("/dev/input");
    if (!dir) return -1;

    struct dirent *e;
    while ((e = readdir(dir))) {
        if (strncmp(e->d_name, "event", 5) != 0) continue;

        char p[256], devname[256];
        snprintf(p, sizeof(p), "/dev/input/%s", e->d_name);
        int fd = open(p, O_RDONLY);
        if (fd < 0) continue;

        if (ioctl(fd, EVIOCGNAME(sizeof(devname)), devname) >= 0 &&
            strcmp(devname, name) == 0) {
            close(fd);
            snprintf(path, len, "%s", p);
            closedir(dir);
            return 0;
        }
        close(fd);
    }
    closedir(dir);
    return -1;
}

static int create_mouse(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return -1;

    ioctl(fd, UI_SET_EVBIT, EV_REL);
    ioctl(fd, UI_SET_RELBIT, REL_X);
    ioctl(fd, UI_SET_RELBIT, REL_Y);
    ioctl(fd, UI_SET_RELBIT, REL_WHEEL);
    ioctl(fd, UI_SET_RELBIT, REL_HWHEEL);
    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    ioctl(fd, UI_SET_KEYBIT, BTN_LEFT);
    ioctl(fd, UI_SET_KEYBIT, BTN_RIGHT);
    ioctl(fd, UI_SET_KEYBIT, BTN_MIDDLE);

    struct uinput_setup s = {0};
    s.id.bustype = BUS_USB;
    s.id.vendor = 0x1234;
    s.id.product = 0x5678;
    snprintf(s.name, UINPUT_MAX_NAME_SIZE, "PS5-Hackintosh-Mouse");

    ioctl(fd, UI_DEV_SETUP, &s);
    ioctl(fd, UI_DEV_CREATE);
    return fd;
}

static int create_keyboard(void) {
    int fd = open("/dev/uinput", O_WRONLY | O_NONBLOCK);
    if (fd < 0) return -1;

    ioctl(fd, UI_SET_EVBIT, EV_KEY);
    int keys[] = {
        KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT,
        KEY_ENTER, KEY_ESC, KEY_TAB, KEY_SPACE,
        KEY_BACKSPACE, KEY_LEFTMETA, KEY_LEFTALT,
        KEY_DELETE, KEY_A, KEY_Z, KEY_F4, KEY_F5,
        0
    };
    for (int i = 0; keys[i]; i++)
        ioctl(fd, UI_SET_KEYBIT, keys[i]);

    struct uinput_setup s = {0};
    s.id.bustype = BUS_USB;
    s.id.vendor = 0x1234;
    s.id.product = 0x5679;
    snprintf(s.name, UINPUT_MAX_NAME_SIZE, "PS5-Hackintosh-Keyboard");

    ioctl(fd, UI_DEV_SETUP, &s);
    ioctl(fd, UI_DEV_CREATE);
    return fd;
}

int main(void) {
    char ds_path[256];

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    printf("[ds-mouse] Looking for DualSense...\n");

    for (int i = 0; i < 30; i++) {
        if (find_dualsense(ds_path, sizeof(ds_path)) == 0) break;
        if (i == 29) {
            printf("[ds-mouse] DualSense not found\n");
            return 1;
        }
        sleep(1);
    }
    printf("[ds-mouse] DualSense: %s\n", ds_path);

    int ds = open(ds_path, O_RDONLY | O_NONBLOCK);
    if (ds < 0) { perror("open DualSense"); return 1; }
    ioctl(ds, EVIOCGRAB, 1);

    int mouse = create_mouse();
    int kbd = create_keyboard();
    if (mouse < 0 || kbd < 0) {
        printf("[ds-mouse] Error creating uinput devices\n");
        return 1;
    }

    usleep(200000);

    char mouse_path[256] = "", kbd_path[256] = "";
    find_uinput_evdev("PS5-Hackintosh-Mouse", mouse_path, sizeof(mouse_path));
    find_uinput_evdev("PS5-Hackintosh-Keyboard", kbd_path, sizeof(kbd_path));

    FILE *env = fopen("/tmp/ds-mouse.env", "w");
    if (env) {
        fprintf(env, "DS_MOUSE_EVDEV=%s\n", mouse_path);
        fprintf(env, "DS_KBD_EVDEV=%s\n", kbd_path);
        fclose(env);
    }

    printf("[ds-mouse] Mouse:    %s\n", mouse_path);
    printf("[ds-mouse] Keyboard: %s\n", kbd_path);
    printf("[ds-mouse] Mapping active\n");

    struct input_absinfo abs_info;
    int mid = 128, range = 128;
    if (ioctl(ds, EVIOCGABS(ABS_X), &abs_info) == 0) {
        mid = (abs_info.maximum + abs_info.minimum) / 2;
        range = (abs_info.maximum - abs_info.minimum) / 2;
        if (range == 0) range = 128;
    }

    int lx = 0, ly = 0, rx = 0, ry = 0;
    struct input_event ev;

    while (running) {
        fd_set fds;
        struct timeval tv = { .tv_sec = 0, .tv_usec = 16000 };
        FD_ZERO(&fds);
        FD_SET(ds, &fds);

        if (select(ds + 1, &fds, NULL, NULL, &tv) > 0) {
            while (read(ds, &ev, sizeof(ev)) == (ssize_t)sizeof(ev)) {
                if (ev.type == EV_ABS) {
                    int c = ((ev.value - mid) * 100) / range;
                    switch (ev.code) {
                    case ABS_X:     lx = c; break;
                    case ABS_Y:     ly = c; break;
                    case ABS_RX:    rx = c; break;
                    case ABS_RY:    ry = c; break;
                    case ABS_HAT0X:
                        emit(kbd, EV_KEY, KEY_LEFT,  ev.value < 0 ? 1 : 0);
                        emit(kbd, EV_KEY, KEY_RIGHT, ev.value > 0 ? 1 : 0);
                        emit_sync(kbd);
                        break;
                    case ABS_HAT0Y:
                        emit(kbd, EV_KEY, KEY_UP,   ev.value < 0 ? 1 : 0);
                        emit(kbd, EV_KEY, KEY_DOWN,  ev.value > 0 ? 1 : 0);
                        emit_sync(kbd);
                        break;
                    }
                } else if (ev.type == EV_KEY) {
                    switch (ev.code) {
                    case BTN_SOUTH:
                        emit(mouse, EV_KEY, BTN_LEFT, ev.value);
                        emit_sync(mouse);
                        break;
                    case BTN_EAST:
                        emit(mouse, EV_KEY, BTN_RIGHT, ev.value);
                        emit_sync(mouse);
                        break;
                    case BTN_NORTH:
                        emit(kbd, EV_KEY, KEY_ENTER, ev.value);
                        emit_sync(kbd);
                        break;
                    case BTN_WEST:
                        emit(kbd, EV_KEY, KEY_SPACE, ev.value);
                        emit_sync(kbd);
                        break;
                    case BTN_TL:
                        emit(kbd, EV_KEY, KEY_ESC, ev.value);
                        emit_sync(kbd);
                        break;
                    case BTN_TR:
                        emit(kbd, EV_KEY, KEY_TAB, ev.value);
                        emit_sync(kbd);
                        break;
                    case BTN_SELECT:
                        emit(kbd, EV_KEY, KEY_LEFTALT, ev.value);
                        emit_sync(kbd);
                        break;
                    case BTN_START:
                        emit(kbd, EV_KEY, KEY_LEFTMETA, ev.value);
                        emit_sync(kbd);
                        break;
                    case BTN_THUMBL:
                        emit(mouse, EV_KEY, BTN_MIDDLE, ev.value);
                        emit_sync(mouse);
                        break;
                    case BTN_THUMBR:
                        emit(kbd, EV_KEY, KEY_BACKSPACE, ev.value);
                        emit_sync(kbd);
                        break;
                    }
                }
            }
        }

        int mx = 0, my = 0, sx = 0, sy = 0;
        if (abs(lx) > DEADZONE)
            mx = (lx - (lx > 0 ? DEADZONE : -DEADZONE)) * MOUSE_SPEED / 100;
        if (abs(ly) > DEADZONE)
            my = (ly - (ly > 0 ? DEADZONE : -DEADZONE)) * MOUSE_SPEED / 100;
        if (abs(rx) > DEADZONE)
            sx = (rx - (rx > 0 ? DEADZONE : -DEADZONE)) * SCROLL_SPEED / 100;
        if (abs(ry) > DEADZONE)
            sy = (ry - (ry > 0 ? DEADZONE : -DEADZONE)) * SCROLL_SPEED / 100;

        if (mx || my) {
            if (mx) emit(mouse, EV_REL, REL_X, mx);
            if (my) emit(mouse, EV_REL, REL_Y, my);
            emit_sync(mouse);
        }
        if (sx || sy) {
            if (sx) emit(mouse, EV_REL, REL_HWHEEL, -sx);
            if (sy) emit(mouse, EV_REL, REL_WHEEL, -sy);
            emit_sync(mouse);
        }
    }

    ioctl(ds, EVIOCGRAB, 0);
    ioctl(mouse, UI_DEV_DESTROY);
    ioctl(kbd, UI_DEV_DESTROY);
    close(ds);
    close(mouse);
    close(kbd);

    printf("[ds-mouse] Stopped\n");
    return 0;
}
