#!/usr/bin/env bash

set -e

# Determine wrt_core path
if [ -d "wrt_core" ]; then
    WRT_CORE_PATH="wrt_core"
elif [ -d "../wrt_core" ]; then
    WRT_CORE_PATH="../wrt_core"
else
    echo "Error: wrt_core directory not found!"
    exit 1
fi

BASE_PATH=$(cd "$WRT_CORE_PATH" && pwd)

Dev=$1
Build_Mod=$2

SUPPORTED_DEVS=()

collect_supported_devs() {
    local ini_file
    local dev_key
    local IFS

    SUPPORTED_DEVS=()

    for ini_file in "$BASE_PATH"/compilecfg/*.ini; do
        [[ -f "$ini_file" ]] || continue

        dev_key=$(basename "$ini_file" .ini)
        if [[ -f "$BASE_PATH/deconfig/$dev_key.config" ]]; then
            SUPPORTED_DEVS+=("$dev_key")
        fi
    done

    if [[ ${#SUPPORTED_DEVS[@]} -eq 0 ]]; then
        return
    fi

    IFS=$'\n' SUPPORTED_DEVS=($(printf '%s\n' "${SUPPORTED_DEVS[@]}" | LC_ALL=C sort))
}

print_usage() {
    echo "Usage: $0 <device> [debug]"
}

print_supported_devs() {
    local index

    echo "Supported devices:"
    for ((index = 0; index < ${#SUPPORTED_DEVS[@]}; index++)); do
        printf "  %d) %s\n" "$((index + 1))" "${SUPPORTED_DEVS[index]}"
    done
}

prompt_select_dev() {
    local input
    local selected_index

    while true; do
        print_supported_devs
        printf "Select device by number (q to quit): "

        if ! read -r input; then
            echo
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*[qQ][[:space:]]*$ ]]; then
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*([0-9]+)[[:space:]]*$ ]]; then
            selected_index=${BASH_REMATCH[1]}
            if ((selected_index >= 1 && selected_index <= ${#SUPPORTED_DEVS[@]})); then
                Dev=${SUPPORTED_DEVS[selected_index - 1]}
                return
            fi
        fi

        echo "Invalid selection. Please enter a number between 1 and ${#SUPPORTED_DEVS[@]}."
    done
}

prompt_select_build_mode() {
    local input

    while true; do
        echo "Build mode:"
        echo "  1) normal"
        echo "  2) debug"
        printf "Select build mode (1-2, q to quit): "

        if ! read -r input; then
            echo
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*[qQ][[:space:]]*$ ]]; then
            echo "Cancelled."
            exit 1
        fi

        if [[ "$input" =~ ^[[:space:]]*1[[:space:]]*$ ]]; then
            Build_Mod=""
            return
        fi

        if [[ "$input" =~ ^[[:space:]]*2[[:space:]]*$ ]]; then
            Build_Mod="debug"
            return
        fi

        echo "Invalid selection. Please enter 1 or 2."
    done
}

is_interactive_terminal() {
    [[ -t 0 && -t 1 ]]
}

if [[ $# -eq 0 ]]; then
    collect_supported_devs

    if [[ ${#SUPPORTED_DEVS[@]} -eq 0 ]]; then
        echo "Error: no supported devices found."
        exit 1
    fi

    if ! is_interactive_terminal; then
        print_usage
        print_supported_devs
        exit 1
    fi

    prompt_select_dev

    if [[ -z $Build_Mod ]]; then
        prompt_select_build_mode
    fi
fi

CONFIG_FILE="$BASE_PATH/deconfig/$Dev.config"
INI_FILE="$BASE_PATH/compilecfg/$Dev.ini"

if [[ ! -f $CONFIG_FILE ]]; then
    echo "Config not found: $CONFIG_FILE"
    exit 1
fi

if [[ ! -f $INI_FILE ]]; then
    echo "INI file not found: $INI_FILE"
    exit 1
fi

read_ini_by_key() {
    local key=$1
    awk -F"=" -v key="$key" '$1 == key {print $2}' "$INI_FILE"
}

remove_uhttpd_dependency() {
    local config_path="$BASE_PATH/../$BUILD_DIR/.config"
    local luci_makefile_path="$BASE_PATH/../$BUILD_DIR/feeds/luci/collections/luci/Makefile"

    if grep -q "CONFIG_PACKAGE_luci-app-quickfile=y" "$config_path"; then
        if [ -f "$luci_makefile_path" ]; then
            sed -i '/luci-light/d' "$luci_makefile_path"
            echo "Removed uhttpd (luci-light) dependency as luci-app-quickfile (nginx) is enabled."
        fi
    fi
}

apply_config() {
    \cp -f "$CONFIG_FILE" "$BASE_PATH/../$BUILD_DIR/.config"

    if grep -qE "(ipq60xx|ipq807x)" "$BASE_PATH/../$BUILD_DIR/.config" &&
        ! grep -q "CONFIG_GIT_MIRROR" "$BASE_PATH/../$BUILD_DIR/.config"; then
        cat "$BASE_PATH/deconfig/nss.config" >> "$BASE_PATH/../$BUILD_DIR/.config"
    fi

    cat "$BASE_PATH/deconfig/compile_base.config" >> "$BASE_PATH/../$BUILD_DIR/.config"

    cat "$BASE_PATH/deconfig/docker_deps.config" >> "$BASE_PATH/../$BUILD_DIR/.config"

    cat "$BASE_PATH/deconfig/proxy.config" >> "$BASE_PATH/../$BUILD_DIR/.config"

    if [[ "$Dev" == "jdcloud_ipq60xx_libwrt" || "$Dev" == "r76s_immwrt" || "$Dev" == "x64_immwrt" ]]; then
        printf '%s\n' \
            'CONFIG_PACKAGE_luci-app-istorex=n' \
            'CONFIG_PACKAGE_luci-app-store=y' \
            'CONFIG_PACKAGE_luci-app-quickstart=n' \
            'CONFIG_PACKAGE_quickstart=n' \
            'CONFIG_PACKAGE_taskd=y' \
            'CONFIG_PACKAGE_luci-lib-taskd=y' \
            'CONFIG_PACKAGE_luci-lib-xterm=y' \
            >> "$BASE_PATH/../$BUILD_DIR/.config"
    fi
}

# 替换 banner
replace_banner() {
    local banner_source="$BASE_PATH/deconfig/banner"
    local banner_target="$BUILD_DIR/package/base-files/files/etc/banner"

    # 确保目标目录存在
    mkdir -p "$(dirname "$banner_target")"

    # 检查自定义 banner 文件是否存在
    if [[ -f "$banner_source" ]]; then
        echo "检测到自定义 banner 文件，正在应用..."
        cp -f "$banner_source" "$banner_target" || {
            echo "警告：复制 banner 文件失败"
            return 1
        }
        echo "文件内容验证:"
        cat "$banner_target" || {
            echo "警告：无法读取 banner 文件内容"
            return 1
        }
    else
        echo "未提供自定义 banner 文件，保持 OpenWrt 默认配置"
    fi
}

apply_r76s_dockerd_defaults() {
    local dockerd_source="$BASE_PATH/patches/993_r76s_dockerd_no_iptables"
    local fq_source="$BASE_PATH/patches/994_r76s_default_fq"
    local defaults_dir="$BASE_PATH/../$BUILD_DIR/package/base-files/files/etc/uci-defaults"

    case "$Dev" in
        r76s_immwrt)
            if [[ -f "$dockerd_source" ]]; then
                install -Dm755 "$dockerd_source" "$defaults_dir/993_r76s_dockerd_no_iptables"
                echo "Applied R76S dockerd no-iptables defaults."
            fi
            if [[ -f "$fq_source" ]]; then
                install -Dm755 "$fq_source" "$defaults_dir/994_r76s_default_fq"
                echo "Applied R76S fq defaults."
            fi
            ;;
    esac
}


REPO_URL=$(read_ini_by_key "REPO_URL")
REPO_BRANCH=$(read_ini_by_key "REPO_BRANCH")
REPO_BRANCH=${REPO_BRANCH:-main}
BUILD_DIR=$(read_ini_by_key "BUILD_DIR")
COMMIT_HASH=$(read_ini_by_key "COMMIT_HASH")
COMMIT_HASH=${COMMIT_HASH:-none}

if [[ -d action_build ]]; then
    BUILD_DIR="action_build"
fi

"$BASE_PATH/update.sh" "$REPO_URL" "$REPO_BRANCH" "$BUILD_DIR" "$COMMIT_HASH" "$Dev"

if [[ "$Dev" == "jdcloud_ipq60xx_immwrt" || "$Dev" == "jdcloud_ipq60xx_libwrt" || "$Dev" == "r76s_immwrt" ]]; then
    mkdir -p "$BASE_PATH/../$BUILD_DIR/package/base-files/files/etc/sysctl.d"
    printf '%s\n' \
        'net.ipv4.tcp_congestion_control=bbr' \
        'net.core.default_qdisc=fq' \
        > "$BASE_PATH/../$BUILD_DIR/package/base-files/files/etc/sysctl.d/99-bbr-fq.conf"
fi

if [[ "$Dev" == "r76s_immwrt" ]]; then
    LED_MENU="$BASE_PATH/../$BUILD_DIR/feeds/luci/modules/luci-mod-system/root/usr/share/luci/menu.d/luci-mod-system.json"
    if [[ -f "$LED_MENU" ]]; then
        python3 -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p)); d.pop("admin/system/leds", None); open(p,"w").write(json.dumps(d, ensure_ascii=False, indent="\t")+"\n")' "$LED_MENU"
    fi
fi

apply_config
apply_r76s_dockerd_defaults

case "$Dev" in
    *)
        remove_uhttpd_dependency
        replace_banner
        ;;
esac

cd "$BASE_PATH/../$BUILD_DIR"
"$BASE_PATH/patches/install_refind_sing_box.sh" "$BASE_PATH/../$BUILD_DIR" "$Dev"
make defconfig

if grep -qE "^CONFIG_TARGET_x86_64=y" "$CONFIG_FILE"; then
    DISTFEEDS_PATH="$BASE_PATH/../$BUILD_DIR/package/emortal/default-settings/files/99-distfeeds.conf"
    if [ -d "${DISTFEEDS_PATH%/*}" ] && [ -f "$DISTFEEDS_PATH" ]; then
        sed -i 's/aarch64_cortex-a53/x86_64/g' "$DISTFEEDS_PATH"
    fi
fi

if [[ $Build_Mod == "debug" ]]; then
    exit 0
fi

TARGET_DIR="$BASE_PATH/../$BUILD_DIR/bin/targets"
if [[ -d $TARGET_DIR ]]; then
    find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec rm -f {} +
fi

make download -j$(($(nproc) * 2))
make -j$(($(nproc) + 1)) || make -j1 V=s

FIRMWARE_DIR="$BASE_PATH/../firmware"
\rm -rf "$FIRMWARE_DIR"
mkdir -p "$FIRMWARE_DIR"
copy_firmware_artifacts() {
    case "$Dev" in
        x64_immwrt)
            find "$TARGET_DIR" -type f \( -name "*squashfs-combined-efi.img.gz" -o -name "*.manifest" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
            ;;
        r76s_immwrt)
            find "$TARGET_DIR" -type f \( -name "*squashfs-*.img.gz" -o -name "*.manifest" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
            ;;
        *)
            find "$TARGET_DIR" -type f \( -name "*.bin" -o -name "*.manifest" -o -name "*.img.gz" -o -name "*.itb" -o -name "*.fip" -o -name "*.ubi" -o -name "*rootfs.tar.gz" \) -exec cp -f {} "$FIRMWARE_DIR/" \;
            ;;
    esac
}

copy_firmware_artifacts
\rm -f "$BASE_PATH/../firmware/Packages.manifest" 2>/dev/null

if [[ -d action_build ]]; then
    make clean
fi
