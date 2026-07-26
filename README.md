# 编译指南

## 1. 环境准备

首先安装 Linux 系统，推荐 Ubuntu LTS。

## 2. 安装编译依赖

```bash
sudo apt -y update
sudo apt -y full-upgrade
sudo apt install -y dos2unix libfuse-dev
sudo bash -c 'bash <(curl -sL https://build-scripts.immortalwrt.org/init_build_environment.sh)'
```

## 3. 使用步骤

1.  克隆仓库：
    ```bash
    git clone https://github.com/BlackHu-art/openwrt_release.git
    ```
2.  进入目录：
    ```bash
    cd openwrt_release
    ```

## 4. 编译固件

使用 `./build.sh` 脚本进行编译，支持以下设备：

### 京东云

*   **太乙(07)**:
    ```bash
    ./build.sh jdcloud_ipq60xx_libwrt
    ./build.sh jdcloud_ipq60xx_immwrt
    ```

### **友善**:

*   **NanoPi R76S**:
    ```bash
    ./build.sh r76s_immwrt
    ./build.sh r76s_lede
    ```

*   **X64**:
    ```bash
    ./build.sh x64_immwrt
    ```

---

## 5. 三方插件

三方插件源自：[https://github.com/kenzok8/small-package.git](https://github.com/kenzok8/small-package.git)

## 6. 项目结构说明

- **wrt_core/**: 核心模块目录，包含所有配置、补丁和脚本。
  - **compilecfg/**: 编译配置文件 (.ini)。
  - **deconfig/**: 默认配置文件 (.config)。
  - **modules/**: 模块化脚本 (general.sh, feeds.sh, packages.sh, system.sh)。
  - **patches/**: 系统和软件包补丁。
  - **scripts/**: 辅助脚本。
  - **update.sh**: 更新逻辑主入口脚本。
  - **pre_clone_action.sh**: 预克隆操作脚本。

- **build.sh**: 主编译脚本，调用 `wrt_core` 中的资源。
- **firmware/**: 编译完成的固件输出目录。

## 7. OAF（应用过滤）功能使用说明

使用 OAF（应用过滤）功能前，需先完成以下操作：

1.  打开系统设置 → 启动项 → 定位到「appfilter」
2.  将「appfilter」当前状态**从已禁用更改为已启用**
3.  完成配置后，点击**启动**按钮激活服务
