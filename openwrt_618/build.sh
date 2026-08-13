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
  r76s) CONFIG_FILE="$ROOT_DIR/openwrt_618/configs/r76s.config" ;;
  x64) CONFIG_FILE="$ROOT_DIR/openwrt_618/configs/x64.config" ;;
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

# Restore requested UI/apps: Aurora config, DiskMan, QuickFile, OpenList2, netspeedtest, Samba, UPnP.
rm -rf package/custom/luci-theme-aurora package/custom/luci-app-aurora-config package/custom/luci-app-diskman package/custom/luci-app-quickfile package/custom/quickfile
rm -rf /tmp/aurora-theme-src /tmp/aurora-config-src /tmp/diskman-src /tmp/quickfile-src
retry git clone --depth 1 https://github.com/eamonxg/luci-theme-aurora.git /tmp/aurora-theme-src
retry git clone --depth 1 https://github.com/eamonxg/luci-app-aurora-config.git /tmp/aurora-config-src
cp -a /tmp/aurora-theme-src package/custom/luci-theme-aurora
cp -a /tmp/aurora-config-src package/custom/luci-app-aurora-config
rm -rf package/custom/luci-theme-aurora/.git package/custom/luci-app-aurora-config/.git
AURORA_TEMPLATE="package/custom/luci-app-aurora-config/root/usr/share/aurora/default.template"
if [ -f "$AURORA_TEMPLATE" ]; then
  sed -i \
    -e "s/option light_brand '.*/option light_brand '#31a1a1'/" \
    -e "s/option light_link '.*/option light_link '#31a1a1'/" \
    -e "s/option dark_brand '.*/option dark_brand '#31a1a1'/" \
    -e "s/option dark_link '.*/option dark_link '#31a1a1'/" \
    -e "s/option nav_type '.*/option nav_type 'mega-menu'/" \
    -e "s/option toolbar_enabled '.*/option toolbar_enabled '1'/" \
    "$AURORA_TEMPLATE"
fi
retry git clone --depth 1 https://github.com/sbwml/luci-app-diskman.git /tmp/diskman-src
cp -a /tmp/diskman-src/luci-app-diskman package/custom/
retry git clone --depth 1 https://github.com/sbwml/luci-app-quickfile.git /tmp/quickfile-src
cp -a /tmp/quickfile-src/luci-app-quickfile package/custom/
cp -a /tmp/quickfile-src/quickfile package/custom/
rm -rf /tmp/aurora-theme-src /tmp/aurora-config-src /tmp/diskman-src /tmp/quickfile-src

# Use latest upstream DockerMan UI/translations instead of stale feed copy.
rm -rf feeds/luci/applications/luci-app-dockerman feeds/luci/libs/luci-lib-docker package/custom/luci-app-dockerman package/custom/luci-lib-docker /tmp/dockerman-src /tmp/luci-lib-docker-src
retry git clone --depth 1 https://github.com/lisaac/luci-app-dockerman.git /tmp/dockerman-src
retry git clone --depth 1 https://github.com/lisaac/luci-lib-docker.git /tmp/luci-lib-docker-src
cp -a /tmp/dockerman-src/applications/luci-app-dockerman package/custom/
cp -a /tmp/luci-lib-docker-src/collections/luci-lib-docker package/custom/
# OpenWrt master/APK rejects versions like v0.3.4; normalize even if CONFIG_USE_APK is disabled later.
sed -i -E 's/^(PKG_VERSION):=v/\1:=/' package/custom/luci-app-dockerman/Makefile package/custom/luci-lib-docker/Makefile
rm -rf /tmp/dockerman-src /tmp/luci-lib-docker-src
# OpenWrt master r8125 is already 9.016.01, same generation as FriendlyWrt's RTL8125 update.

cp -f "$CONFIG_FILE" .config
# Make Aurora the LuCI collection default when luci-ssl pulls a theme.
find feeds/luci/collections -type f -name Makefile -exec sed -i 's/luci-theme-bootstrap/luci-theme-aurora/g' {} +
# This profile is intentionally self-contained. Do not append global deconfig snippets:
# they pull in bulky optional apps. Matching kmods are still exported as a local opkg repo.

# Speed up repeat GitHub Actions builds.
grep -qxF 'CONFIG_CCACHE=y' .config || echo 'CONFIG_CCACHE=y' >> .config

install -Dm755 "$ROOT_DIR/openwrt_618/files/99-openwrt-618-defaults" \
  "$WORK_DIR/package/base-files/files/etc/uci-defaults/99-openwrt-618-defaults"
install -Dm755 "$ROOT_DIR/wrt_core/patches/990_set_aurora_defaults" \
  "$WORK_DIR/package/base-files/files/etc/uci-defaults/990_set_aurora_defaults"

# No automatic third-party kmod feed is installed into the firmware.
# All selected kmods are built as local .ipk packages and bundled below for manual install.

"$ROOT_DIR/wrt_core/patches/install_refind_sing_box.sh" "$WORK_DIR" "$MODEL"
make defconfig
make download -j"$(nproc)"
make -j"$(($(nproc)+1))" || make -j1 V=s

mkdir -p "$FIRMWARE_DIR"
TARGET_DIR="bin/targets"
PKG_REPO_DIR="$ROOT_DIR/package_repo/openwrt_618/$MODEL/latest/all"
rm -rf "$ROOT_DIR/package_repo/openwrt_618/$MODEL/latest"
mkdir -p "$PKG_REPO_DIR"
find bin/packages bin/targets -type f -name '*.ipk' -exec cp -f {} "$PKG_REPO_DIR/" \; 2>/dev/null || true
if ls "$PKG_REPO_DIR"/*.ipk >/dev/null 2>&1; then
  ./scripts/ipkg-make-index.sh "$PKG_REPO_DIR" > "$PKG_REPO_DIR/Packages"
  gzip -9nc "$PKG_REPO_DIR/Packages" > "$PKG_REPO_DIR/Packages.gz"
fi
# Bundle only locally built kmods for optional manual installation.
LOCAL_KMOD_DIR="$WORK_DIR/tmp-local-kmods"
rm -rf "$LOCAL_KMOD_DIR"
mkdir -p "$LOCAL_KMOD_DIR"
find "$PKG_REPO_DIR" -maxdepth 1 -type f -name 'kmod-*.ipk' -exec cp -f {} "$LOCAL_KMOD_DIR/" \;
cat > "$LOCAL_KMOD_DIR/README-zh.txt" <<'EOF_KMOD_README'
本目录是与本固件同一次构建、同一内核 ABI 的本地 kmod 包。
需要时把 .ipk 上传到路由器后执行：
  opkg install /tmp/kmods/*.ipk
不要把这些 kmod 与其它版本固件混装；先确认 uname -r 与固件内核一致。
EOF_KMOD_README
tar -czf "$FIRMWARE_DIR/openwrt_618_${MODEL}_local-kmods.tar.gz" -C "$LOCAL_KMOD_DIR" .
case "$MODEL" in
  x64)
    find "$TARGET_DIR" -type f \( -name '*squashfs-combined-efi.img.gz' -o -name '*.manifest' \) -exec cp -f {} "$FIRMWARE_DIR/" \;
    ;;
  r76s)
    find "$TARGET_DIR" -type f \( -name '*squashfs-*.img.gz' -o -name '*.manifest' \) -exec cp -f {} "$FIRMWARE_DIR/" \;
    ;;
esac
