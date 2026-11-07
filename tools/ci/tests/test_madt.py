"""Tests for tools/make_madt.py: a copy of it runs in a temp tree with made-up APIC.bin files (no console data)."""
import os, shutil, struct, subprocess, sys, tempfile
repo = sys.argv[1]
w = tempfile.mkdtemp()
os.makedirs(f"{w}/tools"); os.makedirs(f"{w}/opencore/ACPI/sony")
shutil.copy(f"{repo}/tools/make_madt.py", f"{w}/tools/make_madt.py")

def madt(entries, fix_len=True):
    body = b"".join(entries)
    t = bytearray(b"APIC" + struct.pack("<I", 44 + len(body)) + b"\x05\x00" + b"SONY  " + b"PS5MADT " + b"\0" * 12 + struct.pack("<II", 0xFEE00000, 1)) + body
    if not fix_len: struct.pack_into("<I", t, 4, 44)
    return bytes(t)
lapic = lambda aid, ln=8: struct.pack("<BBBB", 0, ln, aid, aid) + struct.pack("<I", 1)[: max(0, ln - 4)]
iso = struct.pack("<BBBBIH", 2, 10, 0, 0, 2, 0)
cases = [
    ("valid table, DISABLE_LAPIC=8,9", madt([lapic(i) for i in range(16)] + [iso]), 0),
    ("type 0 entry of length 6 (too short)", madt([lapic(0), lapic(1, 6), lapic(2)]), 1),
    ("type 0 entry of length 2", madt([lapic(0), lapic(1, 2)]), 1),
    ("zero-length entry (old code looped forever)", madt([lapic(0), b"\x05\x00" + b"\0" * 10]), 1),
    ("entry running past the end", madt([lapic(0), b"\x01\x0c\x00\x00"]), 1),
    ("I/O APIC entry of length 8 (needs 12)", madt([lapic(0), struct.pack("<BBBBI", 1, 8, 0, 0, 0)]), 1),
    ("header length disagrees with the file", madt([lapic(0)], fix_len=False), 1),
    ("not a MADT at all", b"FACP" + b"\0" * 60, 1),
    ("valid I/O SAPIC (6, 16 bytes), local SAPIC (7, 17), platform interrupt source (8, 16)",
     madt([lapic(i) for i in range(16)] + [bytes([6, 16]) + bytes(14), bytes([7, 17]) + bytes(15), bytes([8, 16]) + bytes(14)]), 0),
    ("type 6 entry of length 2 (needs 16)", madt([lapic(0), bytes([6, 2])]), 1),
    ("type 7 entry of length 16 (needs 17: the UID string's NUL)", madt([lapic(0), bytes([7, 16]) + bytes(14)]), 1),
    ("type 8 entry of length 2 (needs 16)", madt([lapic(0), bytes([8, 2])]), 1),
    ("type 11 (GICC) entry of length 40 (needs 76)", madt([lapic(0), bytes([11, 40]) + bytes(38)]), 1),
    ("OEM type 0x80 entry of length 4: stepped over", madt([lapic(i) for i in range(16)] + [bytes([0x80, 4, 0, 0])]), 0),
    ("shorter than a table header", b"APIC" + b"\0" * 10, 1),
]
fails = 0
for name, data, want in cases:
    open(f"{w}/opencore/ACPI/sony/APIC.bin", "wb").write(data)
    r = subprocess.run([sys.executable, "-I", f"{w}/tools/make_madt.py", f"{w}/out.aml"], capture_output=True, text=True, timeout=10,
                       env={**os.environ, "DISABLE_LAPIC": "8,9"})
    good = (r.returncode == 0) == (want == 0) and "Traceback" not in r.stderr
    detail = (r.stdout + r.stderr).strip().splitlines()[-1][:110] if (r.stdout + r.stderr).strip() else ""
    if want == 0 and good:
        o = open(f"{w}/out.aml", "rb").read()
        flags = [struct.unpack_from("<I", o, 44 + 8 * i + 4)[0] for i in range(16)]
        good = sum(o) & 0xFF == 0 and struct.unpack_from("<I", o, 4)[0] == len(o) == len(data) + 12 and flags[8] == flags[9] == 0 and flags[7] == 1 \
            and o[len(data):len(data) + 2] == bytes([1, 12])
        detail += f" | checksum ok, length {len(o)}, lapic 8/9 disabled, 7 enabled"
    fails += not good
    print("PASS" if good else "FAIL", name, "->", detail)
shutil.rmtree(w)
print(f"MADT tests: {len(cases) - fails} passed, {fails} failed")
sys.exit(1 if fails else 0)
