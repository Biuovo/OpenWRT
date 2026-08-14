# OpenWrt 自用固件

基于原版`openwrt_release`构建，用到了sbwml大佬的优化。

支持：

- 京东云太乙 ER1（RE-CS-07）
- NanoPi R76S
- x86_64
- OpenWrt 6.18 独立构建流程

## 默认主题

- `luci-theme-aurora`
- `luci-app-aurora-config`
- 默认品牌色：`#31a1a1`
- 默认导航：`mega-menu`
- 默认启用悬浮工具栏

Aurora 主题与配置应用在编译时直接从以下仓库更新：

- https://github.com/eamonxg/luci-theme-aurora
- https://github.com/eamonxg/luci-app-aurora-config

保留原仓库的设备配置、构建脚本和 GitHub Actions 结构，仅将默认主题由 Argon 切换为 Aurora。
