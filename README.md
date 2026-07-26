太乙(RE-CS-07)、NanoPi R76、x86

三方插件源自：[https://github.com/kenzok8/small-package.git](https://github.com/kenzok8/small-package.git)
项目结构说明

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
