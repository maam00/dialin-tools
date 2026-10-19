#!/usr/bin/env python3
"""Golden vectors for the Swift look patcher (FujiSettingsFile.applyingLooks, SettingsLookPatch.swift).

Rebuilds the synthetic X100VI file of `syntheticSettings(k:seed:)` (Tests/DialInCameraTests/SettingsFileAndD185MapTests
.swift, same LCG), runs the real ble/fuji_ble/correlate.py `apply_plan` with the fw 1.10 slot map on a set of
placements, and writes Fixtures/look-patch-vectors.json: per case the changed bytes, the output sha256 and checksum, or
the refusal lines. When the real backup (.dialin/test-fixtures/settings.dat) is here, one plan is applied to it
too and only the two sha256 sums are recorded (the file holds the camera serial; it is never copied).

    python3 -I ios/DialInCamera/Tests/make-look-patch-vectors.py
"""
import hashlib
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent.parent
sys.path.insert(0, str(REPO / "ble"))
from fuji_ble import backupfile as bf  # noqa: E402
from fuji_ble import correlate as co  # noqa: E402

MAP = json.loads((REPO / "ble/maps/x100vi-fw110.json").read_text())
REAL = REPO / ".dialin/test-fixtures/settings.dat"
OUT = HERE / "DialInCameraTests/Fixtures/look-patch-vectors.json"
SIZE = 70524
NAME_REL, NAME_LEN = 0x1E5, 26


def synthetic(k=0x1234, seed=7) -> bytes:
    state = seed
    b = bytearray(SIZE)
    mask = (1 << 64) - 1
    for i in range(0xA8, SIZE):
        state = (state * 6364136223846793005 + 1442695040888963407) & mask
        b[i] = (state >> 33) & 0xFF
    b[0:16] = b"FUJIFILMX-BACKUP"
    b[0x10:0x14] = b"0100"
    b[0x14:0x1A] = b"X100VI"
    b[0x34:0x48] = b"SYNTHETICSERIAL00000"
    b[0x98:0x9C] = (0xA8).to_bytes(4, "little")
    b[0xA0:0xA4] = (SIZE - 0xA8).to_bytes(4, "little")
    b[0x108:0x10C] = bytes(4)
    names = ["Harbor color", "Sunny faces", "Deep blue sea", "Old fisherman", "Faded dock", "Hard noon B&W", "Gritty B&W"]
    for i, n in enumerate(names):
        a = 0xF800 + i * 0x400
        b[a + NAME_REL : a + NAME_REL + NAME_LEN] = n.encode().ljust(NAME_LEN, b"\x00")
        b[a + 0x2F] = 0
        b[a + 0x31] = 1
        b[a + 0x32] = 2
        b[a + 0x84] = 3
    s = sum(b[i] for i in range(0xA8, SIZE) if not 0x108 <= i < 0x10C)
    v = (s + k) & 0xFFFF
    b[0x108] = v & 0xFF
    b[0x109] = v >> 8
    return bytes(b)


def look(name, sim, wb="Auto", kelvin=0, r=0, b=0, dr="DR100", h=0, s=0, color=0, sharp=0, nr=-4, clarity=0,
         grain="Off", cc="Off", ccb="Off"):
    return {"name": name, "film_sim": sim, "grain": grain, "color_chrome": cc, "color_chrome_fx_blue": ccb,
            "white_balance": wb, "kelvin": kelvin, "wb_shift_r": r, "wb_shift_b": b, "dynamic_range": dr,
            "highlight": h, "shadow": s, "color": color, "sharpness": sharp, "noise_reduction": nr, "clarity": clarity,
            "why": ""}


CASES = [
    ("colour on Daylight with a WB shift", [1],
     [look("Shade at noon", "Classic Chrome", wb="Daylight", r=2, b=-4, h=1, s=-1.5, color=2, sharp=-1, clarity=2,
           grain="Weak Small", cc="Strong", ccb="Weak")], False),
    ("Kelvin look", [2], [look("Pier at dusk", "Reala Ace", wb="Kelvin", kelvin=6300, r=1, b=-2, dr="DR200", h=-0.5,
                                 s=0.5, color=1, clarity=-1)], False),
    ("Kelvin 0 means 5500", [6], [look("Kelvin zero", "Velvia", wb="Kelvin", kelvin=0, color=3)], False),
    ("Auto WB with a shift", [3], [look("Warm Auto", "Pro Neg Std", r=3, b=-5, h=2, s=4, color=-1, sharp=2)], False),
    ("mono look skips colour", [4], [look("Rainy B&W", "Acros+R", h=2, s=2, sharp=1, clarity=3, grain="Strong Small",
                                          r=5, b=5, color=4, cc="Strong")], False),
    ("DR400 and grain Weak Large", [5], [look("Dock DR400", "Nostalgic Neg", dr="DR400", h=-2, s=-2, grain="Weak Large",
                                              color=0, sharp=-4, clarity=-5)], False),
    ("needs allow_inferred, refused", [7], [look("Classic Neg", "Classic Neg", wb="Shade", r=1, nr=0, color=4)], False),
    ("needs allow_inferred, allowed", [7], [look("Classic Neg", "Classic Neg", wb="Shade", r=1, nr=0, color=4)], True),
    ("two looks into C3 and C5", [3, 5],
     [look("Shade & Pier", "Acros+Ye", grain="Strong Large", h=1.5),
      look("Sunset dock", "Reala Ace", wb="Daylight", r=-3, b=2, color=3, cc="Weak", ccb="Strong", clarity=1)], False),
    ("a long name is cut to 14", [1], [look("A very long look name indeed", "Velvia", color=1)], False),
    ("unrepresentable highlight", [1], [look("Quarter", "Velvia", h=0.25)], False),
]


def run(data: bytes, slots, looks, allow):
    try:
        out, report, _ = co.apply_plan(data, MAP, looks, bf.x100vi_hypothesis_spec(data), allow, slots)
    except ValueError as e:
        msg = str(e)
        if msg.startswith("refusing to write"):
            return {"ok": False, "refused": [l.strip() for l in msg.split("\n")[1:]]}
        return {"ok": False, "error": msg}
    changed = [[i, out[i]] for i in range(len(data)) if data[i] != out[i]]
    return {"ok": True, "changed": changed, "sha256": hashlib.sha256(out).hexdigest(),
            "checksum": int.from_bytes(out[0x108:0x10A], "little"), "report": report}


def main():
    data = synthetic()
    doc = {"generator": "ios/DialInCamera/Tests/make-look-patch-vectors.py", "base": {"k": 0x1234, "seed": 7,
           "sha256": hashlib.sha256(data).hexdigest()}, "cases": []}
    for name, slots, looks, allow in CASES:
        doc["cases"].append({"name": name, "slots": slots, "looks": looks, "allow_inferred": allow,
                             **run(data, slots, looks, allow)})
    if REAL.exists():
        real = REAL.read_bytes()
        slots, looks = [7], [look("DIALIN C7", "Classic Chrome", wb="Daylight", r=1, b=-3, h=-0.5, s=1, color=1,
                                  sharp=-1, clarity=0, grain="Weak Small", cc="Weak")]
        r = run(real, slots, looks, False)
        doc["real"] = {"file": str(REAL.relative_to(REPO)), "input_sha256": hashlib.sha256(real).hexdigest(),
                       "slots": slots, "looks": looks, "ok": r["ok"], "output_sha256": r.get("sha256")}
    OUT.write_text(json.dumps(doc, indent=1) + "\n")
    print(f"wrote {OUT} ({len(doc['cases'])} cases{', + real file' if 'real' in doc else ''})")
    for c in doc["cases"]:
        print(f"  {c['name']}: {'ok ' + str(len(c['changed'])) + ' bytes' if c['ok'] else c.get('refused') or c.get('error')}")


if __name__ == "__main__":
    main()
