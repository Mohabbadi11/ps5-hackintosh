#!/usr/bin/env python3
"""Put a LINEAR 2560x1440 XR24 dumb buffer on the screen with a recognisable test pattern, then hold the DRM fd.

Run as root after stopping the compositor (sway). Leaves the process sleeping so the framebuffer stays scanned out
until the machine crashes into the next stage. The first 8 pixels of row 0 are a signature (0xDEADBE00+i) so the
buffer can be located in VRAM later.
"""
import ctypes, fcntl, mmap, os, struct, sys, time

W, H = 2560, 1440

def _IOC(d, nr, size): return (d << 30) | (size << 16) | (0x64 << 8) | nr
def IOWR(nr, size): return _IOC(3, nr, size)

class ModeInfo(ctypes.Structure):
    _fields_ = [("clock", ctypes.c_uint32), ("hdisplay", ctypes.c_uint16), ("hsync_start", ctypes.c_uint16),
                ("hsync_end", ctypes.c_uint16), ("htotal", ctypes.c_uint16), ("hskew", ctypes.c_uint16),
                ("vdisplay", ctypes.c_uint16), ("vsync_start", ctypes.c_uint16), ("vsync_end", ctypes.c_uint16),
                ("vtotal", ctypes.c_uint16), ("vscan", ctypes.c_uint16), ("vrefresh", ctypes.c_uint32),
                ("flags", ctypes.c_uint32), ("type", ctypes.c_uint32), ("name", ctypes.c_char * 32)]

class CardRes(ctypes.Structure):
    _fields_ = [("fb_id_ptr", ctypes.c_uint64), ("crtc_id_ptr", ctypes.c_uint64),
                ("connector_id_ptr", ctypes.c_uint64), ("encoder_id_ptr", ctypes.c_uint64),
                ("count_fbs", ctypes.c_uint32), ("count_crtcs", ctypes.c_uint32),
                ("count_connectors", ctypes.c_uint32), ("count_encoders", ctypes.c_uint32),
                ("min_width", ctypes.c_uint32), ("max_width", ctypes.c_uint32),
                ("min_height", ctypes.c_uint32), ("max_height", ctypes.c_uint32)]

class GetConnector(ctypes.Structure):
    _fields_ = [("encoders_ptr", ctypes.c_uint64), ("modes_ptr", ctypes.c_uint64),
                ("props_ptr", ctypes.c_uint64), ("prop_values_ptr", ctypes.c_uint64),
                ("count_modes", ctypes.c_uint32), ("count_props", ctypes.c_uint32),
                ("count_encoders", ctypes.c_uint32), ("encoder_id", ctypes.c_uint32),
                ("connector_id", ctypes.c_uint32), ("connector_type", ctypes.c_uint32),
                ("connector_type_id", ctypes.c_uint32), ("connection", ctypes.c_uint32),
                ("mm_width", ctypes.c_uint32), ("mm_height", ctypes.c_uint32),
                ("subpixel", ctypes.c_uint32), ("pad", ctypes.c_uint32)]

class GetEncoder(ctypes.Structure):
    _fields_ = [("encoder_id", ctypes.c_uint32), ("encoder_type", ctypes.c_uint32),
                ("crtc_id", ctypes.c_uint32), ("possible_crtcs", ctypes.c_uint32),
                ("possible_clones", ctypes.c_uint32)]

class CreateDumb(ctypes.Structure):
    _fields_ = [("height", ctypes.c_uint32), ("width", ctypes.c_uint32), ("bpp", ctypes.c_uint32),
                ("flags", ctypes.c_uint32), ("handle", ctypes.c_uint32), ("pitch", ctypes.c_uint32),
                ("size", ctypes.c_uint64)]

class MapDumb(ctypes.Structure):
    _fields_ = [("handle", ctypes.c_uint32), ("pad", ctypes.c_uint32), ("offset", ctypes.c_uint64)]

class FbCmd(ctypes.Structure):
    _fields_ = [("fb_id", ctypes.c_uint32), ("width", ctypes.c_uint32), ("height", ctypes.c_uint32),
                ("pitch", ctypes.c_uint32), ("bpp", ctypes.c_uint32), ("depth", ctypes.c_uint32),
                ("handle", ctypes.c_uint32)]

class SetCrtc(ctypes.Structure):
    _fields_ = [("set_connectors_ptr", ctypes.c_uint64), ("count_connectors", ctypes.c_uint32),
                ("crtc_id", ctypes.c_uint32), ("fb_id", ctypes.c_uint32), ("x", ctypes.c_uint32),
                ("y", ctypes.c_uint32), ("gamma_size", ctypes.c_uint32), ("mode_valid", ctypes.c_uint32),
                ("mode", ModeInfo)]

GETRESOURCES = IOWR(0xA0, ctypes.sizeof(CardRes))
SETCRTC = IOWR(0xA2, ctypes.sizeof(SetCrtc))
GETENCODER = IOWR(0xA6, ctypes.sizeof(GetEncoder))
GETCONNECTOR = IOWR(0xA7, ctypes.sizeof(GetConnector))
ADDFB = IOWR(0xAE, ctypes.sizeof(FbCmd))
CREATE_DUMB = IOWR(0xB2, ctypes.sizeof(CreateDumb))
MAP_DUMB = IOWR(0xB3, ctypes.sizeof(MapDumb))
SET_MASTER = _IOC(0, 0x1E, 0)

def ioctl(fd, req, obj):
    fcntl.ioctl(fd, req, obj, True)

def u32s(n): return (ctypes.c_uint32 * max(n, 1))()

CARVE, CARVE_SIZE, LOW_LIMIT = 0x450000000, 0x20000000, 0x0F000000

def find_vram(memfd, sig, hint):
    """VRAM offset of the buffer that starts with sig (the carve-out is system RAM): try the predicted spot, then scan from the top."""
    if hint is not None and hint >= 0 and os.pread(memfd, 32, CARVE + hint) == sig:
        return hint
    for off in range(CARVE_SIZE - 0x1000, -1, -0x1000):
        if os.pread(memfd, 32, CARVE + off) == sig:
            return off
    return None

def main():
    fd = os.open("/dev/dri/card0", os.O_RDWR)
    try:
        fcntl.ioctl(fd, SET_MASTER)
    except OSError as e:
        print("SET_MASTER failed (is sway still running?):", e); sys.exit(1)

    res = CardRes()
    ioctl(fd, GETRESOURCES, res)
    crtcs, conns, encs, fbs = u32s(res.count_crtcs), u32s(res.count_connectors), u32s(res.count_encoders), u32s(res.count_fbs)
    res.crtc_id_ptr, res.connector_id_ptr = ctypes.addressof(crtcs), ctypes.addressof(conns)
    res.encoder_id_ptr, res.fb_id_ptr = ctypes.addressof(encs), ctypes.addressof(fbs)
    ioctl(fd, GETRESOURCES, res)
    print("crtcs", list(crtcs)[:res.count_crtcs], "connectors", list(conns)[:res.count_connectors])

    chosen = None
    for i in range(res.count_connectors):
        c = GetConnector(); c.connector_id = conns[i]
        ioctl(fd, GETCONNECTOR, c)
        if c.connection != 1 or c.count_modes == 0:
            continue
        modes = (ModeInfo * c.count_modes)(); encl = u32s(c.count_encoders)
        props, pvals = u32s(c.count_props), (ctypes.c_uint64 * max(c.count_props, 1))()
        c.modes_ptr, c.encoders_ptr = ctypes.addressof(modes), ctypes.addressof(encl)
        c.props_ptr, c.prop_values_ptr = ctypes.addressof(props), ctypes.addressof(pvals)
        ioctl(fd, GETCONNECTOR, c)
        for m in modes:
            print(f"  connector {c.connector_id} mode {m.hdisplay}x{m.vdisplay}@{m.vrefresh} type={m.type:#x}")
        for m in modes:
            if m.hdisplay == W and m.vdisplay == H:
                chosen = (c, m); break
        if chosen: break
    if not chosen:
        print("no connected connector with a 2560x1440 mode"); sys.exit(1)
    c, mode = chosen
    e = GetEncoder(); e.encoder_id = c.encoder_id
    ioctl(fd, GETENCODER, e)
    crtc_id = e.crtc_id or crtcs[0]
    print("using connector", c.connector_id, "crtc", crtc_id)

    # The GPU's BAR0 (256 MB at 0xd0000000) is an alias of the first 256 MB of the VRAM carve-out: macOS' IONDRVFramebuffer only
    # accepts a boot framebuffer inside a PCI BAR, so the picture has to sit in that part. amdgpu hands VRAM out from the top in
    # 16 MB steps; fill the top with dumb buffers (held until the crash) until a new one lands low enough.
    memfd = os.open("/dev/mem", os.O_RDONLY)
    hold, hint = [], None
    for n in range(48):
        d = CreateDumb(); d.width, d.height, d.bpp = W, H, 32
        ioctl(fd, CREATE_DUMB, d)
        mp = MapDumb(); mp.handle = d.handle
        ioctl(fd, MAP_DUMB, mp)
        mm = mmap.mmap(fd, d.size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=mp.offset)
        sig = struct.pack("<8I", *[0xC0DE0000 + (n << 8) + k for k in range(8)])
        mm[0:32] = sig
        off = find_vram(memfd, sig, hint)
        print(f"buffer {n}: VRAM offset {off if off is None else hex(off)}")
        if off is None or off <= LOW_LIMIT:
            break
        hint = off - 0x1000000
        hold.append((d, mm))
    print(f"dumb buffer: handle {d.handle} pitch {d.pitch} size {d.size} ({len(hold)} filler buffers held)")
    f = FbCmd(); f.width, f.height, f.pitch, f.bpp, f.depth, f.handle = W, H, d.pitch, 32, 24, d.handle
    ioctl(fd, ADDFB, f)
    mp = MapDumb(); mp.handle = d.handle
    ioctl(fd, MAP_DUMB, mp)
    mm = mmap.mmap(fd, d.size, mmap.MAP_SHARED, mmap.PROT_READ | mmap.PROT_WRITE, offset=mp.offset)

    # Picture: the welcome screen prepared on the Mac (tools/make_welcome.py -> /root/welcome.raw, XRGB, pitch 10240) copied in one go;
    # without it the old test pattern (8 colour bars, a ramp, an (x,y) code) painted pixel by pixel (slow). Either way row 0 starts with the
    # signature pixels 0xDEADBE00+i, which stage 1 and patch_tripwire.py use to find the buffer in VRAM.
    welcome = "/root/welcome.raw"
    t0 = time.time()
    if os.path.exists(welcome) and os.path.getsize(welcome) == d.pitch * H:
        with open(welcome, "rb") as fh:
            mm[0:d.pitch * H] = fh.read()
        mm[0:32] = struct.pack("<8I", *[0xDEADBE00 + i for i in range(8)])
        print(f"welcome screen copied in {time.time() - t0:.2f} s")
    else:
        bars = [0xFFFFFFFF, 0xFFFFFF00, 0xFF00FFFF, 0xFF00FF00, 0xFFFF00FF, 0xFFFF0000, 0xFF0000FF, 0xFF000000]
        pitch_px = d.pitch // 4
        row = bytearray(d.pitch)
        for y in range(H):
            for x in range(W):
                if y < H // 3:
                    v = bars[x * 8 // W]
                elif y < 2 * H // 3:
                    g = x * 255 // (W - 1)
                    v = 0xFF000000 | (g << 16) | (g << 8) | g
                else:
                    v = 0xFF000000 | ((x & 0xFF) << 8) | (y & 0xFF)
                struct.pack_into("<I", row, x * 4, v)
            if y == 0:
                for i in range(8):
                    struct.pack_into("<I", row, i * 4, 0xDEADBE00 + i)
            mm[y * d.pitch:(y + 1) * d.pitch] = bytes(row)

    sc = SetCrtc()
    conn_arr = u32s(1); conn_arr[0] = c.connector_id
    sc.set_connectors_ptr, sc.count_connectors = ctypes.addressof(conn_arr), 1
    sc.crtc_id, sc.fb_id, sc.mode_valid = crtc_id, f.fb_id, 1
    sc.mode = mode
    ioctl(fd, SETCRTC, sc)
    print("SETCRTC done: linear framebuffer on screen. Holding the fd (Ctrl-C / kill to release).")
    sys.stdout.flush()
    while True:
        time.sleep(3600)

if __name__ == "__main__":
    main()
