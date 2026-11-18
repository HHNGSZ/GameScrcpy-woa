#!/usr/bin/env python3
"""Removes DLLs from a deployment folder that were not built for the target processor.

windeployqt bundles the libraries it finds in the system folders when a Qt library imports one that
it does not consider part of Windows. On a cross build those are the host's programs: the x64
icuuc.dll from system32 ends up next to an ARM64 GameScrcpy.exe, and an ARM64 process cannot load
it. Usage: prune_foreign_dlls.py <folder> <x64|arm64>.
"""

import os
import struct
import sys

MACHINES = {0x8664: "x64", 0xAA64: "arm64", 0x014C: "x86", 0xA641: "arm64ec"}


def machine_of(path: str) -> str:
    try:
        with open(path, "rb") as handle:
            head = handle.read(0x40)
            if head[:2] != b"MZ":
                return ""
            offset = struct.unpack_from("<I", head, 0x3C)[0]
            handle.seek(offset + 4)
            return MACHINES.get(struct.unpack("<H", handle.read(2))[0], "")
    except OSError:
        return ""


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: prune_foreign_dlls.py <folder> <x64|arm64>", file=sys.stderr)
        return 2
    folder, expected = sys.argv[1], sys.argv[2]
    if not os.path.isdir(folder):
        print(f"prune_foreign_dlls: {folder} is not a folder", file=sys.stderr)
        return 1
    removed = []
    for name in sorted(os.listdir(folder)):
        path = os.path.join(folder, name)
        if not os.path.isfile(path) or ".dll" not in name.lower():
            continue
        architecture = machine_of(path)
        # A name like icuuc.dll.zYeNya is what windeployqt leaves behind when a copy does not
        # finish; it is junk in the package either way.
        leftover = ".dll." in name.lower()
        if leftover or (architecture and architecture != expected):
            os.remove(path)
            removed.append(f"{name} ({architecture or 'not a program'})")
    if removed:
        print("removed, not built for " + expected + ": " + ", ".join(removed))
    return 0


if __name__ == "__main__":
    sys.exit(main())
