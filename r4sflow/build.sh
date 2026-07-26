#!/usr/bin/env bash
set -euo pipefail

MODEL=${1:-}
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK_DIR="$ROOT_DIR/action_build"
FIRMWARE_DIR="$ROOT_DIR/firmware"
REPO_URL=${REPO_URL:-https://github.com/openwrt/openwrt.git}
REPO_BRANCH=${REPO_BRANCH:-v25.12.5}

case "$MODEL" in
  r76s) CONFIG_FILE="$ROOT_DIR/r4sflow/configs/r76s.config" ;;
  x64) CONFIG_FILE="$ROOT_DIR/r4sflow/configs/x64.config" ;;
  *) echo "Usage: $0 {r76s|x64}" >&2; exit 1 ;;
esac

retry() { local n=0; until "$@"; do n=$((n+1)); [ "$n" -ge 5 ] && return 1; sleep $((n*5)); done; }

rm -rf "$WORK_DIR" "$FIRMWARE_DIR"
retry git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$WORK_DIR"
cd "$WORK_DIR"

# Extra feeds/packages aligned with openwrt_release plugin set.
cat >> feeds.conf.default <<'EOF_FEEDS'
src-git openwrt_pkgs https://github.com/sbwml/openwrt_pkgs.git;main
src-git momo https://github.com/nikkinikki-org/OpenWrt-momo.git;main
src-git openlist2 https://github.com/sbwml/luci-app-openlist2.git;main
EOF_FEEDS

retry ./scripts/feeds update -a
./scripts/feeds install -a -f
mkdir -p package/custom

# Argon theme/config: repo is not a standard feed; copy packages explicitly.
TMP_ARGON=$(mktemp -d)
if retry git clone --depth 1 https://github.com/sbwml/luci-theme-argon.git "$TMP_ARGON"; then
  [ -d "$TMP_ARGON/luci-theme-argon" ] && rm -rf package/custom/luci-theme-argon && cp -a "$TMP_ARGON/luci-theme-argon" package/custom/
  [ -d "$TMP_ARGON/luci-app-argon-config" ] && rm -rf package/custom/luci-app-argon-config && cp -a "$TMP_ARGON/luci-app-argon-config" package/custom/
fi
rm -rf "$TMP_ARGON"

# DiskMan package, if upstream layout is available.
TMP_DISK=$(mktemp -d)
if retry git clone --depth 1 https://github.com/sbwml/luci-app-diskman.git "$TMP_DISK"; then
  [ -d "$TMP_DISK/luci-app-diskman" ] && rm -rf package/custom/luci-app-diskman && cp -a "$TMP_DISK/luci-app-diskman" package/custom/
fi
rm -rf "$TMP_DISK"

cp -f "$CONFIG_FILE" .config
# Keep old openwrt_release package baseline consistent.
for extra in compile_base docker_deps proxy; do
  [ -f "$ROOT_DIR/wrt_core/deconfig/${extra}.config" ] && cat "$ROOT_DIR/wrt_core/deconfig/${extra}.config" >> .config
done

make defconfig
make download -j"$(nproc)"
make -j"$(($(nproc)+1))" || make -j1 V=s

mkdir -p "$FIRMWARE_DIR"
TARGET_DIR="bin/targets"
case "$MODEL" in
  x64)
    find "$TARGET_DIR" -type f \( -name '*squashfs-combined-efi.img.gz' -o -name '*.manifest' \) -exec cp -f {} "$FIRMWARE_DIR/" \;
    ;;
  r76s)
    find "$TARGET_DIR" -type f \( -name '*squashfs-*.img.gz' -o -name '*.manifest' \) -exec cp -f {} "$FIRMWARE_DIR/" \;
    ;;
esac
