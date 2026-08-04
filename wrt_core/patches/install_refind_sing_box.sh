#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR=${1:?build dir required}
MODEL=${2:?model required}

case "$MODEL" in
  r76s|r76s_immwrt) REFIND_ARCH="arm64" ;;
  x64|x64_immwrt) REFIND_ARCH="amd64" ;;
  *)
    if grep -q '^CONFIG_TARGET_x86_64=y' "$BUILD_DIR/.config" 2>/dev/null; then
      REFIND_ARCH="amd64"
    else
      REFIND_ARCH="arm64"
    fi
    ;;
esac

PKG_DIR="$BUILD_DIR/package/custom/sing-box"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$BUILD_DIR/package/custom"
rm -rf "$BUILD_DIR/feeds/packages/net/sing-box" "$BUILD_DIR/package/feeds/packages/sing-box" "$PKG_DIR"
mkdir -p "$PKG_DIR/files"

if [ "$MODEL" = "r76s_immwrt" ]; then
  TAG="v1.14.0-beta.4-reF1nd-urltest-core"
  VERSION="1.14.0-beta.4"
  URL="https://github.com/Biuovo/sing-box-releases/releases/download/v1.14.0-beta.4-reF1nd-urltest-core/sing-box-1.14.0-beta.4-linux-arm64-musl.tar.gz"
else
  python3 - "$REFIND_ARCH" > "$TMP_DIR/asset.env" <<'PY'
import json, sys, urllib.request
arch=sys.argv[1]
req=urllib.request.Request('https://api.github.com/repos/reF1nd/sing-box-releases/releases/latest', headers={'User-Agent':'openwrt-release-build'})
r=json.load(urllib.request.urlopen(req))
tag=r['tag_name']
want=f'linux-{arch}-musl.tar.gz'
asset=None
for a in r['assets']:
    if a['name'].endswith(want):
        asset=a; break
if not asset:
    raise SystemExit(f'No asset matching {want}')
print(f"TAG='{tag}'")
print(f"VERSION='{tag.lstrip('v')}'")
print(f"URL='{asset['browser_download_url']}'")
PY
  . "$TMP_DIR/asset.env"
fi

echo "Using sing-box: $TAG ($REFIND_ARCH)"
curl -fL --retry 5 --retry-delay 5 --retry-all-errors -o "$TMP_DIR/sing-box.tar.gz" "$URL"
tar -xzf "$TMP_DIR/sing-box.tar.gz" -C "$TMP_DIR"
BIN=$(find "$TMP_DIR" -type f -name sing-box | head -n1)
[ -n "$BIN" ] || { echo "sing-box binary not found in archive" >&2; exit 1; }
install -m 0755 "$BIN" "$PKG_DIR/files/sing-box"

cat > "$PKG_DIR/Makefile" <<EOF
include \$(TOPDIR)/rules.mk

PKG_NAME:=sing-box
PKG_VERSION:=$VERSION
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later

include \$(INCLUDE_DIR)/package.mk

define Package/sing-box
  SECTION:=net
  CATEGORY:=Network
  TITLE:=sing-box reF1nd prebuilt core
  DEPENDS:=+ca-bundle
endef

define Package/sing-box/description
  sing-box core from reF1nd/sing-box-releases.
endef

define Build/Compile
endef

define Package/sing-box/install
	\$(INSTALL_DIR) \$(1)/usr/bin
	\$(INSTALL_BIN) ./files/sing-box \$(1)/usr/bin/sing-box
endef

\$(eval \$(call BuildPackage,sing-box))
EOF

"$PKG_DIR/files/sing-box" version | head -n1 || true
