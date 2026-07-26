#!/usr/bin/env bash
set -euo pipefail

MODEL=${1:-}
ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
WORK_DIR="$ROOT_DIR/action_build"
FIRMWARE_DIR="$ROOT_DIR/firmware"
export CCACHE_DIR="${CCACHE_DIR:-$ROOT_DIR/.ccache}"
mkdir -p "$CCACHE_DIR"
REPO_URL=${REPO_URL:-https://github.com/openwrt/openwrt.git}
REPO_BRANCH=${REPO_BRANCH:-v25.12.5}

case "$MODEL" in
  r76s) CONFIG_FILE="$ROOT_DIR/r4sflow/configs/r76s.config" ;;
  x64) CONFIG_FILE="$ROOT_DIR/r4sflow/configs/x64.config" ;;
  *) echo "Usage: $0 {r76s|x64}" >&2; exit 1 ;;
esac

retry() { local n=0; until "$@"; do n=$((n+1)); [ "$n" -ge 5 ] && return 1; sleep $((n*5)); done; }

setup_kernel_6_18() {
  local tmp
  tmp=$(mktemp -d)
  echo "Switching $MODEL r4sflow kernel tree to OpenWrt master 6.18..."
  retry git clone --depth 1 --filter=blob:none --sparse https://github.com/openwrt/openwrt.git "$tmp"
  retry git -C "$tmp" sparse-checkout set target/linux/generic package/kernel
  case "$MODEL" in
    r76s) retry git -C "$tmp" sparse-checkout add target/linux/rockchip ;;
    x64) retry git -C "$tmp" sparse-checkout add target/linux/x86 ;;
  esac
  rm -rf target/linux/generic package/kernel
  cp -a "$tmp/target/linux/generic" target/linux/generic
  cp -a "$tmp/package/kernel" package/kernel
  case "$MODEL" in
    r76s)
      rm -rf target/linux/rockchip
      cp -a "$tmp/target/linux/rockchip" target/linux/rockchip
      ;;
    x64)
      rm -rf target/linux/x86
      cp -a "$tmp/target/linux/x86" target/linux/x86
      # Keep Linux 6.18 x86_64 kernel config non-interactive.
      local cfg="target/linux/x86/64/config-6.18"
      if [ -f "$cfg" ]; then
        sed -i \
          -e '/^CONFIG_NR_CPUS=/d' \
          -e '/^CONFIG_NR_CPUS_DEFAULT=/d' \
          -e '/^CONFIG_NR_CPUS_RANGE_BEGIN=/d' \
          -e '/^CONFIG_NR_CPUS_RANGE_END=/d' \
          -e '/^CONFIG_MAXSMP=/d' \
          -e '/^# CONFIG_MAXSMP is not set/d' \
          -e '/^CONFIG_X86_POSTED_MSI=/d' \
          -e '/^# CONFIG_X86_POSTED_MSI is not set/d' \
          -e '/^CONFIG_X86_CPU_RESCTRL=/d' \
          -e '/^# CONFIG_X86_CPU_RESCTRL is not set/d' \
          "$cfg"
        cat >> "$cfg" <<'EOF_CFG'
# CONFIG_MAXSMP is not set
# CONFIG_X86_POSTED_MSI is not set
# CONFIG_X86_CPU_RESCTRL is not set
CONFIG_NR_CPUS=64
CONFIG_NR_CPUS_DEFAULT=64
CONFIG_NR_CPUS_RANGE_BEGIN=2
CONFIG_NR_CPUS_RANGE_END=512
EOF_CFG
      fi
      ;;
  esac
  rm -rf "$tmp"
}


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
setup_kernel_6_18

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

# Speed up repeat GitHub Actions builds.
grep -qxF 'CONFIG_CCACHE=y' .config || echo 'CONFIG_CCACHE=y' >> .config

"$ROOT_DIR/wrt_core/patches/install_refind_sing_box.sh" "$WORK_DIR" "$MODEL"
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
