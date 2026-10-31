"""Tiny .env reader and the SMBIOS identity that must not live in the repo.

The tracked opencore/config.plist carries placeholders for the Mac identity (serial, MLB, UUID, ROM). Every build reads them from the
repo's .env (KEY=VALUE lines); if they are missing, random ones are generated and appended to .env so they stay the same from then on.
For something more convincing than random values, generate them with GenSMBIOS (iMac20,2) and put them in .env yourself."""
import os, random, string, uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENV = ROOT / ".env"
KEYS = ("SMBIOS_SERIAL", "SMBIOS_MLB", "SMBIOS_UUID", "SMBIOS_ROM")


def load_env():
    d = {}
    if ENV.exists():
        for line in ENV.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                d[k.strip()] = v.strip().strip('"').strip("'")
    d.update({k: v for k, v in os.environ.items() if k in KEYS})
    return d


def smbios():
    """The four SMBIOS identity values from .env (generated and saved there on first use)."""
    d = load_env()
    rnd = random.SystemRandom()
    alnum = string.ascii_uppercase + string.digits
    gen = {"SMBIOS_SERIAL": lambda: "C02" + "".join(rnd.choice(alnum) for _ in range(9)),
           "SMBIOS_MLB": lambda: "C02" + "".join(rnd.choice(alnum) for _ in range(14)),
           "SMBIOS_UUID": lambda: str(uuid.uuid4()).upper(),
           "SMBIOS_ROM": lambda: "".join(rnd.choice("0123456789abcdef") for _ in range(12))}
    new = []
    for k in KEYS:
        if not d.get(k):
            d[k] = gen[k]()
            new.append(f"{k}={d[k]}")
    if new:
        with open(ENV, "a") as f:
            f.write("\n# Mac identity for the OpenCore config (generated on first build; replace with GenSMBIOS values if you like)\n")
            f.write("\n".join(new) + "\n")
        print("generated SMBIOS identity, saved in .env:", ", ".join(k.split("=")[0] for k in new))
    return d
