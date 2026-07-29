#!/usr/bin/env bash
set -euo pipefail

MODEL=${1:-}
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK_DIR="$ROOT_DIR/action_build"
FIRMWARE_DIR="$ROOT_DIR/firmware"
export CCACHE_DIR="${CCACHE_DIR:-$ROOT_DIR/.ccache}"
mkdir -p "$CCACHE_DIR"
REPO_URL=${REPO_URL:-https://github.com/openwrt/openwrt.git}
REPO_BRANCH=${REPO_BRANCH:-master}

case "$MODEL" in
  r76s) CONFIG_FILE="$ROOT_DIR/r4sflow/configs/r76s.config" ;;
  x64) CONFIG_FILE="$ROOT_DIR/r4sflow/configs/x64.config" ;;
  *) echo "Usage: $0 {r76s|x64}" >&2; exit 1 ;;
esac

retry() { local n=0; until "$@"; do n=$((n+1)); [ "$n" -ge 5 ] && return 1; sleep $((n*5)); done; }


prepare_workdir() {
  local keep
  keep=$(mktemp -d)
  rm -rf "$FIRMWARE_DIR"

  # Preserve restored GitHub cache directories before recloning into action_build.
  [ -d "$WORK_DIR/dl" ] && mv "$WORK_DIR/dl" "$keep/dl"
  [ -d "$WORK_DIR/staging_dir" ] && mv "$WORK_DIR/staging_dir" "$keep/staging_dir"

  if [ -d "$WORK_DIR/.git" ]; then
    retry git -C "$WORK_DIR" fetch --depth 1 origin "$REPO_BRANCH"
    git -C "$WORK_DIR" reset --hard FETCH_HEAD || git -C "$WORK_DIR" reset --hard "$REPO_BRANCH"
    git -C "$WORK_DIR" clean -ffd -e dl -e staging_dir
  else
    rm -rf "$WORK_DIR"
    retry git clone --depth 1 -b "$REPO_BRANCH" "$REPO_URL" "$WORK_DIR"
  fi

  [ -d "$keep/dl" ] && rm -rf "$WORK_DIR/dl" && mv "$keep/dl" "$WORK_DIR/dl"
  [ -d "$keep/staging_dir" ] && rm -rf "$WORK_DIR/staging_dir" && mv "$keep/staging_dir" "$WORK_DIR/staging_dir"
  rm -rf "$keep"
}

prepare_workdir
cd "$WORK_DIR"
# Track OpenWrt master for the latest 6.18 kernel. Runtime kmods come from the matching self-built feed.

# Extra feeds/packages aligned with openwrt_release plugin set.
cat >> feeds.conf.default <<'EOF_FEEDS'
src-git openwrt_pkgs https://github.com/sbwml/openwrt_pkgs.git;main
src-git nikki https://github.com/nikkinikki-org/OpenWrt-nikki.git;main
src-git momo https://github.com/nikkinikki-org/OpenWrt-momo.git;main
src-git openlist2 https://github.com/sbwml/luci-app-openlist2.git;main
EOF_FEEDS

retry ./scripts/feeds update -a
./scripts/feeds install -a -f
mkdir -p package/custom

# Reuse openwrt_release packaging fixes.
BASE_PATH="$ROOT_DIR/wrt_core"
BUILD_DIR="$WORK_DIR"
source "$ROOT_DIR/wrt_core/modules/system.sh"
fix_opkg_check

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

# Speed up repeat GitHub Actions builds.
grep -qxF 'CONFIG_CCACHE=y' .config || echo 'CONFIG_CCACHE=y' >> .config

install -Dm755 "$ROOT_DIR/r4sflow/files/99-r4sflow-defaults"   "$WORK_DIR/package/base-files/files/etc/uci-defaults/99-r4sflow-defaults"

# Add a matching self-built opkg feed for this exact kernel/kmod ABI.
CUSTOM_FEED_URL=""
if [ -n "${GITHUB_REPOSITORY:-}" ]; then
  CUSTOM_FEED_URL="https://raw.githubusercontent.com/${GITHUB_REPOSITORY}/gh-pages/r4sflow/${MODEL}/latest/all"
fi
cat > "$WORK_DIR/package/base-files/files/etc/uci-defaults/98-r4sflow-custom-feed" <<EOF_CUSTOM_FEED
#!/bin/sh
CUSTOM_FEED_URL='$CUSTOM_FEED_URL'
if [ -n "\$CUSTOM_FEED_URL" ]; then
  mkdir -p /etc/opkg
  touch /etc/opkg/customfeeds.conf
  sed -i '/[[:space:]]r4sflow_custom[[:space:]]/d' /etc/opkg/customfeeds.conf
  sed -i '/^option[[:space:]]\+check_signature/d' /etc/opkg.conf
  echo 'option check_signature 0' >> /etc/opkg.conf
  echo "src/gz r4sflow_custom \$CUSTOM_FEED_URL" >> /etc/opkg/customfeeds.conf
fi
exit 0
EOF_CUSTOM_FEED
chmod +x "$WORK_DIR/package/base-files/files/etc/uci-defaults/98-r4sflow-custom-feed"

"$ROOT_DIR/wrt_core/patches/install_refind_sing_box.sh" "$WORK_DIR" "$MODEL"
make defconfig
make download -j"$(nproc)"
make -j"$(($(nproc)+1))" || make -j1 V=s

mkdir -p "$FIRMWARE_DIR"
TARGET_DIR="bin/targets"
PKG_REPO_DIR="$ROOT_DIR/package_repo/r4sflow/$MODEL/latest/all"
rm -rf "$ROOT_DIR/package_repo/r4sflow/$MODEL/latest"
mkdir -p "$PKG_REPO_DIR"
find bin/packages bin/targets -type f -name '*.ipk' -exec cp -f {} "$PKG_REPO_DIR/" \; 2>/dev/null || true
if ls "$PKG_REPO_DIR"/*.ipk >/dev/null 2>&1; then
  ./scripts/ipkg-make-index.sh "$PKG_REPO_DIR" > "$PKG_REPO_DIR/Packages"
  gzip -9nc "$PKG_REPO_DIR/Packages" > "$PKG_REPO_DIR/Packages.gz"
fi
case "$MODEL" in
  x64)
    find "$TARGET_DIR" -type f \( -name '*squashfs-combined-efi.img.gz' -o -name '*.manifest' \) -exec cp -f {} "$FIRMWARE_DIR/" \;
    ;;
  r76s)
    find "$TARGET_DIR" -type f \( -name '*squashfs-*.img.gz' -o -name '*.manifest' \) -exec cp -f {} "$FIRMWARE_DIR/" \;
    ;;
esac
