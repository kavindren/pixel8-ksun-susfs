#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-only
# Pixel 8 (shiba) GKI kernel with KernelSU-Next + SUSFS for the stock firmware.
#
# Builds kernel/common at the exact tag the stock kernel was built from, adds
# KernelSU-Next (pershoot/dev-susfs) and SUSFS, and swaps the kernel inside the
# stock boot.img. Vendor modules, dtbo, vendor_boot etc. stay stock.
#
# Commands (run from the directory this script lives in):
#   detect   resolve the kernel/common tag from `uname -r` of the device
#            (or KERNEL_RELEASE=...) and write target.env
#   sync     repo init + repo sync of the matching GKI manifest
#   stock    dump boot/init_boot of the active slot (adb + root) into stock/,
#            undoing a KernelSU LKM patch of init_boot
#   prepare  reset common/ to the tag, apply SUSFS + KernelSU-Next
#   build    Kleaf build of //common:kernel_aarch64
#   repack   put the new kernel into stock/boot.img -> release/
#   manager  download the KernelSU-Next manager CI build matching the kernel
#   verify   check CRCs of the device's stock modules against the new kernel
#   all      sync + prepare + build + repack + manager
set -euo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

GKI_BRANCH="android14-6.1"
KSUN_REF="${KSUN_REF:-pershoot/dev-susfs}"
SUSFS_REF="${SUSFS_REF:-pershoot/gki-${GKI_BRANCH}-dev}"
MAGISK_VERSION="v31.0"

TARGET_ENV="$ROOT/target.env"
COMMON="$ROOT/common"
KSU_DIR="$ROOT/KernelSU-Next"
SUSFS_DIR="$ROOT/susfs4ksu"
STOCK_DIR="$ROOT/stock"
RELEASE="$ROOT/release"
MAGISKBOOT="$ROOT/tools-host/magiskboot"
KERNEL_OUT="$ROOT/bazel-bin/common/kernel_aarch64"

KERNEL_RELEASE="${KERNEL_RELEASE:-}"
TAG="${TAG:-}"
MANIFEST_BRANCH="${MANIFEST_BRANCH:-}"
BUILD_NUMBER="${BUILD_NUMBER:-}"

log() { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# grep -m1 closes the pipe early; keep the SIGPIPE of strings out of pipefail
linux_version() { { strings "$1" || true; } | grep -m1 'Linux version'; }

# Values from the environment win over target.env.
load_target() {
    [ -f "$TARGET_ENV" ] || return 0
    local k v
    while IFS='=' read -r k v; do
        case "$k" in
            KERNEL_RELEASE|TAG|MANIFEST_BRANCH|BUILD_NUMBER)
                [ -n "${!k}" ] || printf -v "$k" '%s' "$v" ;;
        esac
    done < "$TARGET_ENV"
}

require_target() {
    [ -n "$TAG" ] && [ -n "$MANIFEST_BRANCH" ] && [ -n "$BUILD_NUMBER" ] ||
        die "target is unknown: run '$0 detect' first"
}

device_slot() {
    local slot
    slot="$(adb shell getprop ro.boot.slot_suffix | tr -d '\r')"
    [ -n "$slot" ] || die "no device (adb) or no A/B slot"
    [[ "$(adb shell 'su -c id' 2>/dev/null)" == *uid=0* ]] || die "root (su) on the device is required"
    echo "$slot"
}

detect() {
    local krel="$KERNEL_RELEASE"
    [ -n "$krel" ] || krel="$(adb shell uname -r | tr -d '\r')"
    [[ "$krel" =~ ^6\.1\.[0-9]+-android14-[0-9]+-g([0-9a-f]{12})-ab([0-9]+)$ ]] ||
        die "unexpected kernel release '$krel' (want 6.1.x-android14-N-g<sha>-ab<build>)"
    local sha="${BASH_REMATCH[1]}" build="${BASH_REMATCH[2]}"

    log "Looking up the kernel/common tag for g$sha"
    local tag
    tag="$(git ls-remote https://android.googlesource.com/kernel/common "refs/tags/${GKI_BRANCH}-*" |
        awk -v s="$sha" 'index($1, s) == 1 { t = $2; sub("^refs/tags/", "", t); sub("\\^\\{\\}$", "", t); print t }' |
        sort -uV | tail -n1)"
    [ -n "$tag" ] || die "no ${GKI_BRANCH} tag points at $sha"

    local branch="common-${tag%_r*}"
    git ls-remote --exit-code --heads https://android.googlesource.com/kernel/manifest "$branch" >/dev/null ||
        die "manifest branch $branch not found"

    cat > "$TARGET_ENV" <<EOF
KERNEL_RELEASE=$krel
TAG=$tag
MANIFEST_BRANCH=$branch
BUILD_NUMBER=$build
EOF
    cat "$TARGET_ENV"
}

clean_common() {
    log "Cleaning common/"
    cd "$COMMON"
    rm -f drivers/kernelsu
    git reset -q --hard
    git clean -q -fd
}

sync() {
    require_target
    command -v repo >/dev/null || die "repo is not installed"
    # repo sync refuses to touch a modified project
    [ -e "$COMMON/.git" ] && clean_common
    log "Syncing $MANIFEST_BRANCH"
    cd "$ROOT"
    repo init -u https://android.googlesource.com/kernel/manifest -b "$MANIFEST_BRANCH" --depth=1
    repo sync -c -j"$(nproc)" --no-clone-bundle --no-tags
}

update_sources() {
    log "KernelSU-Next: official origin/dev + $KSUN_REF"
    if [ ! -d "$KSU_DIR/.git" ]; then
        git clone -b dev https://github.com/KernelSU-Next/KernelSU-Next "$KSU_DIR"
        git -C "$KSU_DIR" remote add pershoot https://github.com/pershoot/KernelSU-Next
    fi
    git -C "$KSU_DIR" fetch origin dev
    git -C "$KSU_DIR" fetch pershoot dev-susfs
    # Kbuild derives the version from merge-base(HEAD, origin/<branch prefix>),
    # so origin must be the official repo and the branch must be named dev-*.
    git -C "$KSU_DIR" checkout -q -B dev-susfs "$KSUN_REF"
    git -C "$KSU_DIR" log --oneline -1

    log "susfs4ksu: $SUSFS_REF"
    if [ ! -d "$SUSFS_DIR/.git" ]; then
        git clone -b "gki-$GKI_BRANCH" https://gitlab.com/simonpunk/susfs4ksu.git "$SUSFS_DIR"
        git -C "$SUSFS_DIR" remote add pershoot https://gitlab.com/pershoot/susfs4ksu.git
    fi
    git -C "$SUSFS_DIR" fetch origin "gki-$GKI_BRANCH"
    git -C "$SUSFS_DIR" fetch pershoot "gki-$GKI_BRANCH-dev"
    git -C "$SUSFS_DIR" checkout -q -B "gki-$GKI_BRANCH-dev" "$SUSFS_REF"
    git -C "$SUSFS_DIR" log --oneline -1
}

checkout_tag() {
    log "Checking out $TAG"
    cd "$COMMON"
    # Only the commit is needed. A deeper fetch on top of the shallow repo sync
    # checkout makes the server send the whole history (gigabytes).
    git fetch -q --depth=1 aosp "refs/tags/$TAG"
    git checkout -q --detach FETCH_HEAD
    # The stock kernel was built from the commit, not from a tag: without local
    # tags setlocalversion prints -android14-N-g<sha12>, exactly like stock.
    git tag -l | xargs -r git tag -d >/dev/null
    git log --oneline -1
}

apply_susfs() {
    log "Applying SUSFS"
    cd "$COMMON"
    cp "$SUSFS_DIR"/kernel_patches/fs/* fs/
    cp "$SUSFS_DIR"/kernel_patches/include/linux/* include/linux/
    # 6.1.157+ includes <trace/hooks/blk.h> right where the patch expects
    # nothing: drop it for patching and put it back afterwards.
    sed -i '/^#include <trace\/hooks\/blk.h>$/d' fs/namespace.c
    patch -p1 --no-backup-if-mismatch -F 0 < "$SUSFS_DIR/kernel_patches/50_add_susfs_in_gki-$GKI_BRANCH.patch"
    sed -i '/^#include "internal.h"$/a #include <trace/hooks/blk.h>' fs/namespace.c
}

apply_ksu() {
    log "Integrating KernelSU-Next"
    cd "$COMMON/drivers"
    ln -sfn "$(realpath --relative-to=. "$KSU_DIR/kernel")" kernelsu
    grep -q 'kernelsu/' Makefile || printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> Makefile
    grep -q 'drivers/kernelsu/Kconfig' Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' Kconfig
}

apply_config() {
    log "Kernel config and build tweaks"
    cd "$COMMON"
    cat >> arch/arm64/configs/gki_defconfig <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
EOF
    # gki_defconfig no longer matches savedefconfig output
    sed -i 's/POST_DEFCONFIG_CMDS="check_defconfig"/POST_DEFCONFIG_CMDS=""/' build.config.gki
    # system_dlkm modules are signed with the stock build key, so for our
    # kernel they are "unsigned" and could not export protected symbols
    # (Wi-Fi, Bluetooth, ... would break).
    rm -f android/abi_gki_protected_exports_*
    perl -ni -e 'print unless /^[ \t]*"protected_exports_list"[ \t]*:[ \t]*"android\/abi_gki_protected_exports_\w+",[ \t]*$/' BUILD.bazel
    # no "-dirty" in the kernel release string
    sed -i "s/printf '%s' -dirty/printf '%s' ''/" scripts/setlocalversion
}

prepare() {
    require_target
    [ -e "$COMMON/.git" ] || die "no kernel sources: run '$0 sync' first"
    update_sources
    clean_common
    checkout_tag
    apply_susfs
    apply_ksu
    apply_config
}

build() {
    require_target
    [ -L "$COMMON/drivers/kernelsu" ] || die "sources are not prepared: run '$0 prepare' first"
    log "Building (BUILD_NUMBER=$BUILD_NUMBER)"
    cd "$ROOT"
    BUILD_NUMBER="$BUILD_NUMBER" tools/bazel build \
        --config=stamp --config=local --nokleaf_localversion \
        //common:kernel_aarch64
    linux_version "$KERNEL_OUT/Image"
}

ensure_magiskboot() {
    [ -x "$MAGISKBOOT" ] && return
    log "Fetching magiskboot from Magisk $MAGISK_VERSION"
    local tmp
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/magisk.apk" \
        "https://github.com/topjohnwu/Magisk/releases/download/$MAGISK_VERSION/Magisk-$MAGISK_VERSION.apk"
    unzip -q -o "$tmp/magisk.apk" lib/x86_64/libmagiskboot.so -d "$tmp"
    install -D -m755 "$tmp/lib/x86_64/libmagiskboot.so" "$MAGISKBOOT"
    rm -rf "$tmp"
}

# Same result as `ksud boot-restore` without a backup: drop kernelsu.ko and
# put the original init back.
unpatch_init_boot() {
    local img="$1" work
    work="$(mktemp -d)"
    cp "$img" "$work/init_boot.img"
    (
        cd "$work"
        mb() { "$MAGISKBOOT" "$@" >/dev/null 2>&1; }
        mb unpack init_boot.img
        if mb cpio ramdisk.cpio "exists .backup/.magisk"; then
            die "init_boot is patched by Magisk: take init_boot.img from the factory image"
        fi
        mb cpio ramdisk.cpio "exists kernelsu.ko" || exit 0
        echo "init_boot is patched by KernelSU LKM, restoring the stock ramdisk"
        mb cpio ramdisk.cpio "rm kernelsu.ko"
        if mb cpio ramdisk.cpio "exists init.real"; then
            mb cpio ramdisk.cpio "mv init.real init"
        fi
        if mb cpio ramdisk.cpio "exists stock_image.sha1"; then
            mb cpio ramdisk.cpio "rm stock_image.sha1"
        fi
        mb repack init_boot.img new.img
        cp new.img "$img"
    )
    rm -rf "$work"
}

stock() {
    ensure_magiskboot
    local slot p
    slot="$(device_slot)"
    mkdir -p "$STOCK_DIR"
    for p in boot init_boot; do
        log "Dumping $p$slot"
        adb shell "su -c 'dd if=/dev/block/by-name/$p$slot of=/data/local/tmp/$p.img bs=4M 2>/dev/null && chmod 644 /data/local/tmp/$p.img'"
        adb pull "/data/local/tmp/$p.img" "$STOCK_DIR/$p.img"
        adb shell "su -c 'rm -f /data/local/tmp/$p.img'"
    done
    unpatch_init_boot "$STOCK_DIR/init_boot.img"
    ls -la "$STOCK_DIR"
}

ksu_base() { git -C "$KSU_DIR" merge-base HEAD origin/dev; }
ksu_version() { echo $((30000 + $(git -C "$KSU_DIR" rev-list --count "$(ksu_base)"))); }
ksu_uapi() { grep -m1 'KERNEL_SU_UAPI_VERSION' "$KSU_DIR/uapi/supercall.h" | grep -o '[0-9]\+' | tail -n1; }
susfs_version() { grep -m1 '^#define SUSFS_VERSION' "$COMMON/include/linux/susfs.h" | cut -d'"' -f2; }

repack() {
    require_target
    ensure_magiskboot
    [ -f "$KERNEL_OUT/Image" ] || die "no kernel: run '$0 build' first"
    [ -f "$STOCK_DIR/boot.img" ] || die "no $STOCK_DIR/boot.img: run '$0 stock' or put it there"

    local work new_ver stock_ver
    work="$(mktemp -d)"
    cp "$STOCK_DIR/boot.img" "$work/boot.img"
    (cd "$work" && "$MAGISKBOOT" unpack boot.img)
    new_ver="$(linux_version "$KERNEL_OUT/Image")"
    stock_ver="$(linux_version "$work/kernel")"
    # stock/boot.img must come from the firmware the kernel was built for
    [ "$new_ver" = "$stock_ver" ] || die "stock boot.img is from another firmware:
  stock: $stock_ver
  built: $new_ver"

    log "Repacking"
    cp "$KERNEL_OUT/Image" "$work/kernel"  # recompressed as lz4_legacy like stock
    (cd "$work" && "$MAGISKBOOT" repack boot.img boot-new.img)

    mkdir -p "$RELEASE"
    local out="$RELEASE/boot-$TAG-ksun$(ksu_version)-susfs$(susfs_version).img"
    cp "$work/boot-new.img" "$out"
    rm -rf "$work"
    local images=("$out")
    if [ -f "$STOCK_DIR/init_boot.img" ]; then
        cp "$STOCK_DIR/init_boot.img" "$RELEASE/init_boot-stock.img"
        images+=("$RELEASE/init_boot-stock.img")
    else
        warn "no $STOCK_DIR/init_boot.img: flash a stock (not LKM-patched) init_boot yourself"
    fi
    write_build_info "${images[@]}"
    log "Done"
    ls -la "$RELEASE"
}

write_build_info() {
    {
        echo "Kernel release : $KERNEL_RELEASE"
        echo "kernel/common  : $TAG ($(git -C "$COMMON" rev-parse --short=12 HEAD))"
        echo "KernelSU-Next  : $(ksu_version) (uapi $(ksu_uapi)), pershoot/dev-susfs $(git -C "$KSU_DIR" rev-parse --short=12 HEAD)," \
             "official dev $(git -C "$KSU_DIR" rev-parse --short=12 "$(ksu_base)")"
        echo "SUSFS          : $(susfs_version), susfs4ksu $(git -C "$SUSFS_DIR" rev-parse --short=12 HEAD)"
        echo
        local f
        for f in "$@"; do
            echo "$(sha256sum < "$f" | cut -d' ' -f1)  $(basename "$f")"
        done
    } > "$RELEASE/build-info.txt"
}

# The manager compares the kernel UAPI version, not the release number, so a
# kernel built from KernelSU-Next dev needs the manager CI build of the same
# official commit. Needs an authenticated `gh`.
manager() {
    [ -d "$KSU_DIR/.git" ] || die "no KernelSU-Next checkout: run '$0 prepare' first"
    command -v gh >/dev/null || die "gh (GitHub CLI) is not installed"
    local sha run tmp
    sha="$(ksu_base)"
    run="$(gh api "repos/KernelSU-Next/KernelSU-Next/actions/workflows/build-manager-ci.yml/runs?head_sha=$sha" \
        --jq '[.workflow_runs[] | select(.conclusion == "success")][0].id // empty')"
    [ -n "$run" ] || die "no successful manager CI run for $sha"
    log "Downloading the manager (spoofed) from CI run $run ($sha)"
    tmp="$(mktemp -d)"
    gh run download "$run" -R KernelSU-Next/KernelSU-Next -n manager-spoofed -D "$tmp"
    mkdir -p "$RELEASE"
    mv -f "$tmp"/*.apk "$RELEASE/"
    rm -rf "$tmp"
    ls "$RELEASE"/*.apk
}

verify() {
    ensure_magiskboot
    [ -f "$KERNEL_OUT/vmlinux.symvers" ] || die "no kernel: run '$0 build' first"
    local slot work clang_ver img rd
    slot="$(device_slot)"
    work="$(mktemp -d)"
    clang_ver="$(grep -m1 '^CLANG_VERSION=' "$COMMON/build.config.constants" | cut -d= -f2)"

    log "Pulling stock modules from the device"
    cat > "$work/dump.sh" <<EOF
D=/data/local/tmp/kmods
rm -rf \$D && mkdir -p \$D/vendor_dlkm \$D/system_dlkm
cp /vendor_dlkm/lib/modules/*.ko \$D/vendor_dlkm/
find /system_dlkm/lib/modules -name '*.ko' -exec cp {} \$D/system_dlkm/ \\;
for p in vendor_kernel_boot vendor_boot; do
    dd if=/dev/block/by-name/\${p}$slot of=\$D/\${p}.img bs=4M 2>/dev/null
done
chmod -R a+rX \$D
EOF
    adb push "$work/dump.sh" /data/local/tmp/kmods-dump.sh >/dev/null
    adb shell "su -c 'sh /data/local/tmp/kmods-dump.sh'"
    adb pull /data/local/tmp/kmods "$work/" >/dev/null
    adb shell "su -c 'rm -rf /data/local/tmp/kmods /data/local/tmp/kmods-dump.sh'"

    for img in "$work"/kmods/vendor_kernel_boot.img "$work"/kmods/vendor_boot.img; do
        python3 "$ROOT/tools/mkbootimg/unpack_bootimg.py" --boot_img "$img" --out "${img%.img}" >/dev/null
        for rd in "${img%.img}"/vendor_ramdisk*; do
            [ -f "$rd" ] || continue
            "$MAGISKBOOT" decompress "$rd" "$rd.cpio" >/dev/null 2>&1 || continue
            mkdir -p "$rd.d"
            (cd "$rd.d" && "$MAGISKBOOT" cpio "$rd.cpio" extract >/dev/null 2>&1) || continue
        done
    done

    log "Checking module CRCs against the new kernel"
    python3 "$ROOT/scripts/check_modversions.py" \
        --tools "$ROOT/prebuilts/clang/host/linux-x86/clang-$clang_ver/bin" \
        "$KERNEL_OUT/vmlinux.symvers" "$work/kmods"
    rm -rf "$work"
}

usage() {
    sed -n '/^# Commands/,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'
    exit 1
}

cmd="${1:-}"
[ "$cmd" = detect ] || load_target
case "$cmd" in
    detect)  detect ;;
    sync)    sync ;;
    stock)   stock ;;
    prepare) prepare ;;
    build)   build ;;
    repack)  repack ;;
    manager) manager ;;
    verify)  verify ;;
    all)
        [ -f "$STOCK_DIR/boot.img" ] || die "no $STOCK_DIR/boot.img: run '$0 stock' first"
        sync; prepare; build; repack; manager ;;
    *)       usage ;;
esac
