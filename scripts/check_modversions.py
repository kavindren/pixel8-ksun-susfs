#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Check that kernel modules will load on a newly built kernel.

Every module built with CONFIG_MODVERSIONS records the CRC of each kernel
symbol it uses (the __versions section). This compares those CRCs, taken from
the device's stock modules, with the CRCs exported by the new kernel
(vmlinux.symvers). Symbols exported by other modules are skipped.
"""
import argparse
import pathlib
import struct
import subprocess
import sys
import tempfile

# struct modversion_info on 64-bit: unsigned long crc; char name[56];
MODVERSION_SIZE = 64


def parse_symvers(path):
    crcs = {}
    for line in path.read_text().splitlines():
        crc, sym, *_ = line.split("\t")
        crcs[sym] = int(crc, 16)
    return crcs


def module_versions(tools, ko):
    with tempfile.NamedTemporaryFile() as tmp:
        result = subprocess.run(
            [tools / "llvm-objcopy", "-O", "binary", "--only-section=__versions", ko, tmp.name],
            capture_output=True)
        if result.returncode:
            return []
        data = pathlib.Path(tmp.name).read_bytes()
    versions = []
    for off in range(0, len(data) - MODVERSION_SIZE + 1, MODVERSION_SIZE):
        crc, = struct.unpack_from("<Q", data, off)
        name = data[off + 8:off + MODVERSION_SIZE].split(b"\0", 1)[0].decode()
        versions.append((name, crc & 0xffffffff))
    return versions


def module_exports(tools, ko):
    result = subprocess.run([tools / "llvm-nm", "--defined-only", ko],
                            capture_output=True, text=True, check=True)
    prefix = "__ksymtab_"
    return {line.split()[-1][len(prefix):] for line in result.stdout.splitlines()
            if line.split() and line.split()[-1].startswith(prefix)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tools", type=pathlib.Path, required=True,
                        help="directory with llvm-objcopy and llvm-nm")
    parser.add_argument("symvers", type=pathlib.Path, help="vmlinux.symvers of the new kernel")
    parser.add_argument("dirs", type=pathlib.Path, nargs="+", help="directories with stock *.ko")
    args = parser.parse_args()

    kernel = parse_symvers(args.symvers)
    # lib/modules/<release>_16k/ holds modules for the 16 KB page size kernel
    # (developer option); they never load on the regular 4 KB kernel.
    modules = sorted(ko for d in args.dirs for ko in d.rglob("*.ko")
                     if not any(part.endswith("_16k") for part in ko.parts))
    if not modules:
        sys.exit("no modules found")

    exported_by_modules = set()
    for ko in modules:
        exported_by_modules |= module_exports(args.tools, ko)

    checked = mismatches = missing = 0
    for ko in modules:
        name = ko.relative_to(next(d for d in args.dirs if ko.is_relative_to(d)))
        for sym, crc in module_versions(args.tools, ko):
            if sym in kernel:
                checked += 1
                if kernel[sym] != crc:
                    mismatches += 1
                    print(f"CRC MISMATCH {name}: {sym} module={crc:#010x} kernel={kernel[sym]:#010x}")
            elif sym not in exported_by_modules and sym != "module_layout":
                missing += 1
                print(f"MISSING {name}: {sym}")

    print(f"modules: {len(modules)} files ({len({ko.name for ko in modules})} unique), "
          f"symbols checked: {checked}, CRC mismatches: {mismatches}, missing: {missing}")
    sys.exit(1 if mismatches or missing else 0)


if __name__ == "__main__":
    main()
