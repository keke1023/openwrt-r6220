# OpenWrt 云编译配置（多机型）

通过 GitHub Actions 免费云编译 OpenWrt 固件，已内置：

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

> **多机型**：往 `config/` 丢任意 `xxx.config` 即可自动加入编译矩阵，无需改动 workflow。

## 使用方法

1. 把本仓库 **Fork** 到你自己的 GitHub 账号（建议设为 **Private** 避免暴露你的配置）。
2. 进入仓库 `Settings → Actions → General`，确认 `Workflow permissions` 为 **Read and write**（用于上传 Release）。
3. 进入 `Actions` 标签，选择 `Build OpenWrt (Multi-device)`，点 **Run workflow**。`prepare` 步骤会扫描 `config/` 下所有 `*.config`，为每个机型起一个并行 job。
4. 等待编译完成（R6220 通常 1~2 小时）。
5. 到仓库 `Releases` 页面下载固件（文件名含 `sysupgrade` 的是升级包，`factory` 的是首次刷机包）。

## 刷机须知（重要）

- **R6220 只有 128MB NAND**，ssr-plus 全套体积较大。若刷入后剩余空间紧张：
  - 编辑 `config/r6220.config`，删掉不需要的 `INCLUDE_*` 行（只保留你实际要用的协议）。
  - 或删掉 `luci-app-ttyd`、`luci-app-upnp` 等增强项。
- 首次刷机用 `*-factory.img`；已刷过 OpenWrt 用 `*-sysupgrade.bin`。
- 刷机前请确认当前 bootloader 版本，R6220 有分区的坑，建议参考官方 Wiki。

## 自定义

- **改插件**：编辑对应机型的 `config/xxx.config`。当前为手动触发（Run workflow），改完到 Actions 手动跑一次即可。
- **加新源**：在 `scripts/diy-part1.sh` 里追加 `src-git xxx <仓库地址>`。
- **改默认设置**：在 `scripts/diy-part2.sh` 里调整 IP / 时区 / 密码。
- **换源码**：改 `build.yml` 里的 `REPO_URL` / `REPO_BRANCH`（如改用 immortalwrt）。

## 编译多个机型

本仓库的 workflow 已支持 **matrix 多机型并行编译**，机制如下：

1. `prepare` job 扫描 `config/*.config`，把文件名汇总成机型矩阵。
2. `build` job 按矩阵为每个机型起一个独立并行 job，互不影响（`fail-fast: false`，单个失败不影响其余）。
3. 每个机型的 Release 标签按文件名区分，如 `r6220-2026.08.04-1745`。

**新增一个机型，只需两步：**

- 在 `config/` 下新建该机型的 `.config`（例如 `x86_64.config`、`newifi-d2.config`）。
- 到 Actions 点 Run workflow，自动就会多编一个。

> 提示：免费账户并行 job 数有限（通常 2 个），机型较多时会排队；跨架构机型（x86 / ramips / armvirt）每个 job 都要重新克隆源码，耗时较长，建议优先用同架构机型，或用 `actions/cache` 缓存 `dl/` 与 `feeds/`。

## 常见问题

- **编译超时（6 小时）**：精简插件、确保 `make download` 阶段已把源码包下全。
- **空间不足**：见上面的"刷机须知"，删减插件。
- **ngrokc / frpc 编译失败**：本配置基于 immortalwrt，luci-app-ngrokc、ngrokc、luci-app-frpc 均为官方 feeds 自带，无需第三方源；如报错请确认 immortalwrt 对应分支（openwrt-23.05）下这些包仍然存在。
- **ssr-plus 编译失败**：确认 `fw876/helloworld` 源可访问（diy-part1.sh 已添加）；它提供 luci-app-ssr-plus 及 xray/v2ray 等底层依赖。
- **libustream 冲突（`check_data_file_clashes: Package libustream-openssl wants to install .../libustream-ssl.so But that file is already provided by libustream-mbedtls`）**：immortalwrt 23.05 的 `include/target.mk` 默认包里自带 **openssl 版** `libustream-openssl`，而 `luci-ssl`（mbedtls 版）会硬拉 `libustream-mbedtls`，两者提供同名 `libustream-ssl.so` 故冲突。本仓库已统一改用 **`luci-ssl-openssl`**（openssl 版）+ 显式 `CONFIG_PACKAGE_libustream-mbedtls=n` 规避。若你手动加机型 config，请勿混用 `luci-ssl` 与默认的 openssl 后端。
