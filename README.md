# OpenWrt 云编译配置 —— Netgear R6220

通过 GitHub Actions 免费云编译 Netgear R6220 固件，已内置：

- `luci-app-ssr-plus`（含 ShadowsocksR/V2ray/Xray/Trojan/Kcptun/NaiveProxy）
- `luci-app-frpc`
- `luci-app-ngrokc`
- 默认管理地址：`192.168.6.1`

## 目录结构

```
.
├── .github/workflows/build.yml   # Actions 编译流程
├── config/r6220.config           # 机型与插件配置（.config）
├── scripts/diy-part1.sh          # 编译前：添加第三方源
└── scripts/diy-part2.sh          # 编译前：改默认管理 IP 等
```

## 使用方法

1. 把本仓库 **Fork** 到你自己的 GitHub 账号（建议设为 **Private** 避免暴露你的配置）。
2. 进入仓库 `Settings → Actions → General`，确认 `Workflow permissions` 为 **Read and write**（用于上传 Release）。
3. 进入 `Actions` 标签，选择 `Build OpenWrt for Netgear R6220`，点 **Run workflow**。
4. 等待编译完成（R6220 通常 1~2 小时）。
5. 到仓库 `Releases` 页面下载固件（文件名含 `sysupgrade` 的是升级包，`factory` 的是首次刷机包）。

## 刷机须知（重要）

- **R6220 只有 128MB NAND**，ssr-plus 全套体积较大。若刷入后剩余空间紧张：
  - 编辑 `config/r6220.config`，删掉不需要的 `INCLUDE_*` 行（只保留你实际要用的协议）。
  - 或删掉 `luci-app-ttyd`、`luci-app-upnp` 等增强项。
- 首次刷机用 `*-factory.img`；已刷过 OpenWrt 用 `*-sysupgrade.bin`。
- 刷机前请确认当前 bootloader 版本，R6220 有分区的坑，建议参考官方 Wiki。

## 自定义

- **改插件**：编辑 `config/r6220.config`。改完 push 即会自动触发编译（也可关闭 push 触发，纯手动）。
- **加新源**：在 `scripts/diy-part1.sh` 里追加 `src-git xxx <仓库地址>`。
- **改默认设置**：在 `scripts/diy-part2.sh` 里调整 IP / 时区 / 密码。
- **换源码**：改 `build.yml` 里的 `REPO_URL` / `REPO_BRANCH`（如改用 immortalwrt）。

## 常见问题

- **编译超时（6 小时）**：精简插件、确保 `make download` 阶段已把源码包下全。
- **空间不足**：见上面的"刷机须知"，删减插件。
- **ngrokc / frpc 编译失败**：本配置基于 immortalwrt，luci-app-ngrokc、ngrokc、luci-app-frpc 均为官方 feeds 自带，无需第三方源；如报错请确认 immortalwrt 对应分支（openwrt-23.05）下这些包仍然存在。
- **ssr-plus 编译失败**：确认 `fw876/helloworld` 源可访问（diy-part1.sh 已添加）；它提供 luci-app-ssr-plus 及 xray/v2ray 等底层依赖。
