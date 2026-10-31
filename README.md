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

## EZVIZ CS-W3-WD1200G（32MB 改造版）

`config/ezviz_cs-w3-wd1200g-32m.config` 对应 **EZVIZ W3**（ipq40xx / IPQ4018 + 128MB DDR3），
前提是**已把原厂 16MB SPI-NOR 换成 32MB 芯片**。

### 为什么要换芯片

| 项目 | 原厂 16MB | 改造 32MB |
|---|---|---|
| firmware 分区 | `0x180000` + `0xE80000`（14.5 MiB） | `0x180000` + `0x1E80000`（30.5 MiB） |
| IMAGE_SIZE | `14848k` | `31232k` |
| 刷完剩余 overlay | 约 3 MB | 约 12-15 MB |
| 能否装 xray-core | ❌ 精简版也要 5.8 MB | ✅ |

16MB 布局下装任何 xray 系核心都会 `No space left on device` —— 这就是本机型要改 32MB 的原因。
分区扩容与 `IMAGE_SIZE` 放开由 `scripts/diy-part2.sh` 第 16 段自动完成（幂等，重复执行无副作用）。

### 改造流程（顺序不能错）

1. **先备份原片**：用编程器 dump 原 16MB 全片，至少保住 `0x00000000 ~ 0x00180000`（1.5 MiB）。
   这段含 SBL1 / MIBIB / QSEE / CDT / DDRPARAMS / APPSBLENV / APPSBL / ART，
   其中 **ART 里有 MAC 地址和 ath10k 射频预校准数据（precal_art_1000 / precal_art_5000）**，
   丢了 Wi-Fi 功率和校准就废了，且无法从别处重建。
2. **换芯片**：MX25L12805D（SOP-16 300mil）→ MX25L25635F 或 W25Q256JV（同封装引脚兼容）。
3. **烧回引导区**：把第 1 步的 1.5 MiB 原样写到新片同一偏移，其余空间留空。
4. **编译**：用本 config + 仓库 workflow，无需手动改 DTS。
5. **刷入**：`sysupgrade -n` 只写 firmware 分区，引导区不动。

> ⚠️ **换片后原厂的 16MB MTD 备份回滚方式全部失效**（分区偏移已变）。
> 一旦刷坏只能靠编程器重写引导区救砖 —— 动手前请确认手里有编程器和 SOP-16 转接座。

### 内存说明（第二道坎）

128MB + 双 ath10k 本来就紧。上游 `generic.mk` 已默认
`DEVICE_PACKAGES := -kmod-ath10k-ct kmod-ath10k-ct-smallbuffers`，
即 **smallbuffers 变体是默认行为**（省约 20MB，代价是 5GHz 峰值 494→438 Mbps）。

本 config 在此之上又做了：砍 IPv6 双栈（`odhcpd`/`odhcp6c`）、ssr-plus 只留 Xray 核心、
注入 32MB zram（`/etc/init.d/zramswap`，不走 RAM/2 的 `zram-swap` 包）。
预计运行时基线 57-69 MB，给 xray（vless+reality）留 50 MB 左右 —— **能跑但没有富余**，
不要再叠 adblock / mwan3 / docker。

### Wi-Fi 校准不能改名

设备符号必须沿用上游 `ezviz_cs-w3-wd1200g-eup`：`BOARD_NAME` 决定 `ipq-wifi` BDF 包名，
DTS 里 `qcom,ath10k-calibration-variant = "ezviz-cs-w3-wd1200g-eup"` 决定驱动加载哪个校准文件。
改成 `-32m` 之类会导致 BDF 找不到，Wi-Fi 功率/校准直接退化。

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
- **mt7981 / aarch64 机型编译 rust 失败（卡在 `compiling rust`、`error: failed to compile rust toolchain`）**：`luci-app-ssr-plus`（fw876/helloworld）在 **aarch64（mt7981 = filogic 平台）** 上，Shadowsocks 客户端/服务端的**默认值就是 Rust 版**（`default ..._INCLUDE_Shadowsocks_Rust_Client if aarch64 || x86_64`），会拉 `shadowsocks-rust` 编译整套 rust 工具链；此外 `INCLUDE_MosDNS` 在 aarch64 上也默认 `y`（mosdns 本身是 Go，但会多拉一次 Go 工具链）。旧写法 `INCLUDE_Shadowsocks_Rust=n` 是**已废弃符号名**（新版已拆成 `_Rust_Client` / `_Rust_Server`），被 `make defconfig` 当无效符号忽略，于是 aarch64 的 Rust 默认值生效——这正解释了"只有 mt7981 这类机型失败"，而 mt7621/ipq40xx 默认走 libev 不受影响。本仓库所有 config 已显式改为：`INCLUDE_Shadowsocks_Libev_Client=y`、`INCLUDE_Shadowsocks_Rust_Client=n`、`INCLUDE_Shadowsocks_Rust_Server=n`、`INCLUDE_MosDNS=n`。**新增 aarch64 机型 config 时务必照此显式指定，否则又会掉回 Rust 默认值。**

> 验证：在 `make defconfig` 后执行 `grep -i rust .config`，应无 `=y` 行。
- **ipq40xx（R619AC 等）内核编译在打补丁阶段失败（`Hunk #1 FAILED at 1814`、`Patch failed! ... 401-mmc-sdhci-msm-comment-unused-sdhci_msm_set_clock.patch`）**：该补丁位于 immortalwrt 源码树 `target/linux/ipq40xx/patches-5.15/`，意图注释掉 `sdhci-msm.c` 的自定义时钟函数、改用通用 `sdhci_set_clock`。但其上下文基于旧版内核，与当前 5.15.198 的 `sdhci-msm.c`（稳定版 backport 已改动 `sdhci_msm_set_clock` 函数体）对不上，导致 `make` 在 `target/linux/compile` 阶段就挂掉；且 5.15.198 中 `.set_clock = sdhci_msm_set_clock` 仍引用该函数（并非死代码），所以补丁即便打上也会造成未定义引用。本仓库在 workflow 克隆源码后、编译前**直接删除该补丁**（保留内核原生时钟处理函数，可正常编译）。注意：这是 immortalwrt openwrt-23.05 分支 HEAD 的一个过时补丁，未来若上游修正或切换内核版本，可移除该删除步骤。
