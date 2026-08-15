#!/usr/bin/env bash
set -euo pipefail

BUILD_DIR=${1:?build dir required}
MODEL=${2:?model required}

case "$MODEL" in
  r76s|r76s_openwrt|jdcloud_ipq60xx_immwrt|jdcloud_ipq60xx_libwrt|er1|er1_immwrt)
    REFIND_ARCH="arm64"
    ;;
  x64|x64_openwrt|x86|x86_64)
    # Use universal amd64, not amd64v3.
    REFIND_ARCH="amd64"
    ;;
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

python3 - "$REFIND_ARCH" > "$TMP_DIR/asset.env" <<'PY'
import json, re, sys, urllib.request
arch=sys.argv[1]
req=urllib.request.Request('https://api.github.com/repos/Biuovo/sing-box-releases/releases?per_page=20', headers={'User-Agent':'openwrt-release-build'})
releases=json.load(urllib.request.urlopen(req))
rel=next((x for x in releases if not x.get('draft')), None)
if not rel:
    raise SystemExit('No non-draft release found in Biuovo/sing-box-releases')
tag=rel['tag_name']
want=f'linux-{arch}-musl.tar.gz'
asset=next((a for a in rel.get('assets', []) if a['name'].endswith(want)), None)
if not asset:
    names=', '.join(a['name'] for a in rel.get('assets', []))
    raise SystemExit(f'No asset matching {want} in {tag}; assets: {names}')
# APK v3 only accepts Alpine version syntax. In particular, SemVer's
# "-beta.N" must be written as "_betaN"; a bare hyphen is
# reserved for the final "-rN" package revision added by OpenWrt.
m=re.search(r'v?(\d+(?:\.\d+)+(?:[-_][0-9A-Za-z.]+)?)', tag)
if m:
    version=m.group(1).replace('-', '_').lower()
    version=re.sub(r'_(alpha|beta|pre|rc|cvs|svn|git|hg|p)\.(\d+)$', r'_\1\2', version)
    valid=r'\d+(?:\.\d+)*(?:[a-z])?(?:_(?:alpha|beta|pre|rc|cvs|svn|git|hg|p)\d*)*'
    if not re.fullmatch(valid, version):
        version=(rel.get('published_at') or rel.get('created_at') or '1970-01-01')[:10].replace('-', '.')
else:
    version=(rel.get('published_at') or rel.get('created_at') or '1970-01-01')[:10].replace('-', '.')
print(f"TAG='{tag}'")
print(f"VERSION='{version}'")
print(f"URL='{asset['browser_download_url']}'")
PY
. "$TMP_DIR/asset.env"

echo "Using Biuovo sing-box: $TAG ($REFIND_ARCH)"
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
  TITLE:=sing-box Biuovo reF1nd urltest prebuilt core
  DEPENDS:=+ca-bundle
endef

define Package/sing-box/description
  sing-box core from Biuovo/sing-box-releases.
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
