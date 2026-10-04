# Pixel 8: stock GKI kernel with KernelSU-Next and SUSFS

This script builds the **stock** GKI kernel for the Pixel 8 (shiba) from Google's
sources and builds [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next)
and [SUSFS](https://gitlab.com/simonpunk/susfs4ksu) into it. Only `boot.img`
changes. Every other partition (vendor modules, dtbo, vendor_boot) stays stock,
so the kernel runs on the current firmware, including Android 17, where custom
kernels made for Android 16 (Sultan-Kernel, for example) bootloop.

## What you get

- The kernel is built from `kernel/common` at **the exact tag** Google built the
  stock kernel of the firmware from. `uname -r` and `/proc/version` match stock
  byte for byte. `.config` differs only by the `CONFIG_KSU*` options.
- KernelSU-Next is built into the kernel (GKI mode, not LKM). The kernel side
  comes from [pershoot/KernelSU-Next](https://github.com/pershoot/KernelSU-Next)
  (branch `dev-susfs`), because the official KernelSU-Next removed SUSFS support
  from its code.
- SUSFS v2.x from `simonpunk/susfs4ksu` (branch `gki-android14-6.1`) with
  compatibility fixes from [pershoot](https://gitlab.com/pershoot/susfs4ksu).
- The stock `boot.img` is repacked with `magiskboot`. The AVB footer, with
  its patch level and fingerprint, is preserved.
- The KernelSU-Next manager is downloaded from KernelSU-Next CI, built from the
  exact commit the kernel was built from.

## Tested

| | |
|---|---|
| Device | Pixel 8 (shiba) |
| Firmware | Android 17, `CP3A.260905.009`, patch level 2026-09-05 |
| Kernel | `6.1.162-android14-11-g2ec90535fa34-ab15810641` (tag `android14-6.1-2026-03_r18`) |
| KernelSU-Next | 33319 (v3.4.0-25-g9ba1a51e), UAPI 5 |
| SUSFS | v2.3.0 |

Results:
- The phone boots. Wi‑Fi, Bluetooth, LTE, ZygiskNext, LSPosed and the
  [susfs4ksu](https://github.com/sidex15/susfs4ksu-module) R28 module work.
- 331 stock modules (vendor_kernel_boot, vendor_dlkm, system_dlkm) make
  17,830 references to kernel symbols: 0 CRC mismatches, 0 missing symbols.
- The build is reproducible: a second `all` run from scratch produced a
  byte-identical `boot.img`.

The "boot with 16 KB page size" developer option is not supported: only the
regular 4 KB page size kernel is built.

Other Pixels on the `android14-6.1` kernel (8 Pro, 8a, etc.) will most likely
build the same way, but have not been tested. Always run `verify` before
flashing on them.

## Requirements

- Linux x86_64. About 15 GB of disk space: sources and prebuilts ~10 GB, Bazel
  cache ~4 GB. 16+ GB of RAM is recommended.
- `repo`, `git`, `curl`, `unzip`, `python3`, `perl`, `patch`, `adb`, `fastboot`.
- [`gh`](https://cli.github.com/) after `gh auth login`: needed to download the
  manager from GitHub Actions.
- An unlocked bootloader.
- Root on the phone (KernelSU-Next LKM is fine), only for the `detect`, `stock`
  and `verify` commands. Without the phone everything can be set by hand, see
  below.

## Building

```sh
git clone https://github.com/kavindren/pixel8-ksun-susfs
cd pixel8-ksun-susfs

./build_ksun_susfs.sh detect   # finds the kernel tag from the phone's `uname -r` -> target.env
./build_ksun_susfs.sh stock    # dumps boot and init_boot of the active slot -> stock/
./build_ksun_susfs.sh all      # sync + prepare + build + repack + manager
./build_ksun_susfs.sh verify   # (recommended) checks stock module CRCs against the new kernel
```

The results land in `release/`:
- `boot-<tag>-ksun<version>-susfs<version>.img` — the kernel;
- `init_boot-stock.img` — the stock init_boot;
- `KernelSU_Next_*-spoofed_*.apk` — the manager;
- `build-info.txt` — exact source commits and sha256 of the images.

The first build takes a while because `repo sync` downloads the toolchain and
the sources. The compilation itself takes about 5 minutes on 16 threads.

### Without the phone

```sh
KERNEL_RELEASE=6.1.162-android14-11-g2ec90535fa34-ab15810641 ./build_ksun_susfs.sh detect
```

In this case take `boot.img` and `init_boot.img` from the
[factory image](https://developers.google.com/android/images#shiba) of your
firmware and put them into `stock/`.

### Individual commands

| Command | What it does |
|---|---|
| `detect` | reads `uname -r` (or `KERNEL_RELEASE`), finds the `kernel/common` tag and the manifest branch, writes `target.env` |
| `sync` | `repo init` + `repo sync` of the matching GKI manifest |
| `stock` | dumps `boot`/`init_boot` over adb with root; if init_boot is patched by KernelSU LKM, restores the stock ramdisk |
| `prepare` | resets `common/` to the tag, applies SUSFS, integrates KernelSU-Next, adjusts the config |
| `build` | builds the kernel with Kleaf |
| `repack` | puts the kernel into `stock/boot.img`; also checks that the boot.img is from the same firmware |
| `manager` | downloads the manager from KernelSU-Next CI for the kernel's commit |
| `verify` | checks the symbol CRCs of the phone's stock modules against the new kernel |

The KernelSU-Next and SUSFS revisions can be pinned with the `KSUN_REF` and
`SUSFS_REF` environment variables. By default the tips of
`pershoot/dev-susfs` and `pershoot/gki-android14-6.1-dev` are used.

## Flashing

```sh
adb reboot bootloader
fastboot flash boot release/boot-*.img
fastboot flash init_boot release/init_boot-stock.img
fastboot reboot
```

`init_boot` must be stock. An init_boot patched for LKM would try to load a
second copy of KernelSU.

After booting, install the manager from `release/`. KernelSU-Next accepts only
**one** manager, and spoofed builds get a new random package name with every
version. So after installing the new manager, uninstall the old one: the kernel
switches to the new one within a few seconds. Root, modules and the allowlist
live in `/data/adb` and are not lost.

Rollback: flash `boot.img` and `init_boot.img` from the factory image (or your
own backups) with the same `fastboot flash`.

## After an OTA

An OTA overwrites `boot`, and root is gone. To get the kernel back:

1. Get root temporarily with KernelSU-Next LKM (or skip this step and use
   `KERNEL_RELEASE` + the factory image, see above).
2. Run `./build_ksun_susfs.sh detect && ./build_ksun_susfs.sh stock && ./build_ksun_susfs.sh all`.
3. Flash the kernel as described above.

If `detect` cannot find the tag, Google has not published the sources of that
kernel build yet. They usually appear within a few days after the release.

## Why it is done this way

- **A tag, not a branch.** Pixel vendor modules are built against one specific
  kernel. At the exact tag the symbol CRCs are guaranteed to match (which is
  what `verify` checks). The version string also comes out identical to stock:
  local tags are deleted from `common/`, the `-dirty` suffix is removed, and
  `BUILD_NUMBER` is taken from the stock `-ab<number>`.
- **`abi_gki_protected_exports` is removed.** The GKI modules in `system_dlkm`
  are signed with the stock build's key. For our kernel they are "unsigned",
  and without this they could not export protected symbols: Wi‑Fi, Bluetooth,
  etc. would break.
- **The manager comes from CI.** The manager compares the kernel's UAPI
  version, not the release number. A kernel built from the `dev` branch can be
  newer than the latest manager release, and then the released manager
  complains that the manager version is too old.
- **`fs/namespace.c`.** Since 6.1.157 it has `#include <trace/hooks/blk.h>`,
  which the SUSFS patch trips over. The script removes it while the patch is
  applied and puts it back afterwards.

## Layout

After `sync` this directory becomes a `repo` workspace: `common/`, `build/`,
`prebuilts/` etc. appear next to the script. `.gitignore` lets only the tool
itself into git: `build_ksun_susfs.sh`, `scripts/`, `README.md`, `LICENSE`.

## Credits

- [KernelSU-Next](https://github.com/KernelSU-Next/KernelSU-Next) and
  [KernelSU](https://github.com/tiann/KernelSU);
- [pershoot](https://github.com/pershoot/KernelSU-Next) — SUSFS integration for
  KernelSU-Next;
- [simonpunk/susfs4ksu](https://gitlab.com/simonpunk/susfs4ksu);
- [sidex15/susfs4ksu-module](https://github.com/sidex15/susfs4ksu-module);
- [WildKernels/GKI_KernelSU_SUSFS](https://github.com/WildKernels/GKI_KernelSU_SUSFS) —
  build tricks borrowed from there;
- [Magisk](https://github.com/topjohnwu/Magisk) — `magiskboot`.

## License

[GPL-2.0](LICENSE), same as the Linux kernel.

## Disclaimer

Whatever you do to your device, you do at your own risk. Back up the stock
`boot.img` and `init_boot.img` before flashing.
