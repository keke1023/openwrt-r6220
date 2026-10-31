#!/bin/bash
# DIY-P1: 在 ./scripts/feeds update/install 之前运行（当前位于 openwrt 源码根目录）
# 作用：添加第三方软件源，确保 luci-app-ssr-plus 使用 fw876/helloworld 版本（带 xray reality 补丁）。
#
# 为什么不用 feeds 追加 + -f 覆盖：
#   早期写法是在 feeds.conf.default 末尾追加 src-git helloworld，再靠 build.yml 的
#   `feeds install -a -f` 让同名包后者覆盖前者。但实测 runner 上 feeds update 拉取
#   helloworld 源不稳定（被 GitHub 限流/超时静默失败），导致 feeds/helloworld 根本没生成、
#   -f 无从覆盖，最终编出的是 immortalwrt 官方 luci 源的 ssr-plus（无 reality 补丁）。
#
# 改为 helloworld 官方 README 的 Method 1：直接 clone 到 package/helloworld 目录。
#   OpenWrt 构建系统会直接扫描 package/ 目录，package/ 下的同名包优先级高于 feeds/ 同名包，
#   无需依赖 feeds 覆盖逻辑，100% 确定收录 helloworld 版 luci-app-ssr-plus 及其底层依赖。

SRC_BRANCH="${SOURCE_BRANCH:-openwrt-23.05}"
# 当前编译的机型 config 基名（由 build.yml 以 TARGET_CONFIG 注入，如 a3004ns-dual.config）。
# 用于对 16MB 小闪存机型做 helloworld commit pin；未注入时按"大闪存"处理，走 master 最新。
TARGET_CONFIG="${TARGET_CONFIG:-}"

# 分支隔离：仅「真正的老 18.06（openwrt-18.06，4.x 内核）」跳过 helloworld master 源；
# openwrt-18.06-k5.4 是「18.06 包基础 + 5.4 新内核」，兼容 helloworld / ngrokc / frpc，放行。
# 注：config-18.06/ 下现有 dw33d（128MB NAND，走 master 最新）与 a3004ns-dual
#     （16MB SPI NOR，由下方 SMALL_FLASH_PATTERNS + PIN_COMMIT 强制 pin 到 xray v1.8.4）。
case "$SRC_BRANCH" in
  openwrt-18.06) echo "==> 旧版 18.06(老内核 4.x)，跳过 helloworld master 源（不兼容）"; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# 分支策略（按 SOURCE_BRANCH 选 helloworld 版本）：
#   - 18.06-k5.4：默认用 master 分支最新提交（ssr-plus 190-3+ / xray-core v26.x，需 Go 1.26）。
#       例外：命中 SMALL_FLASH_PATTERNS 的 16MB 机型会 checkout 到 PIN_COMMIT（xray v1.8.4），
#       否则 xray 单独一项就要 7.5MiB，16MB 分区放不下（详见下方 pin 段说明）。
#   - 23.05 / master：用 helloworld 的 master 分支（非默认 dev 分支）。fw876/helloworld 的
#       DEFAULT 分支是 dev（ssr-plus 196-7），但用户要的是 master 分支（ssr-plus 190-3）。
#       clone 必须显式 -b master，否则会误拉 dev。xray-core 随 master 走（v25/v26，Go 1.26）。
# 全量 clone（非浅克隆）：后续如需 checkout 历史 commit，浅克隆不可靠。
# ---------------------------------------------------------------------------

# 全量 clone，并显式 -b master：fw876/helloworld 的 DEFAULT 分支是 dev（ssr-plus 196-7），
# 不指定分支会误拉 dev，必须用 -b master 拿 ssr-plus 190-3 的版本。
echo "==> 添加 luci-app-ssr-plus 源（fw876/helloworld，clone 到 package/helloworld）"
rm -rf package/helloworld
git clone -b master https://github.com/fw876/helloworld.git package/helloworld
if [ ! -d "package/helloworld/luci-app-ssr-plus" ]; then
  echo "!! 错误：helloworld clone 未包含 luci-app-ssr-plus，请检查网络/源可用性"
  exit 1
fi
echo "==> helloworld 已就绪，luci-app-ssr-plus 来自：package/helloworld/luci-app-ssr-plus"

# ---------------------------------------------------------------------------
# 16MB 小闪存机型：pin 到「体积最省 + reality 完整可用」的历史 commit
# ---------------------------------------------------------------------------
# 为什么必须 pin：helloworld master 最新 xray-core 已是 v26.x（官方 release 的
#   Xray-linux-mips32le.zip 达 23.5MiB，strip 进 squashfs 约 7.5MiB），叠加
#   luci+ssr-plus+基础系统后 16MB（firmware 分区 15.75MiB）连 overlay 都留不出来。
#
# 选 a201839（2023-10-15，xray-core v1.8.4）的依据（已逐文件核实）：
#   1) reality 全链路支持 —— 以下四处均含 reality_publickey/realitySettings：
#        luasrc/model/cbi/shadowsocksr/client-config.lua  （节点配置表单）
#        luasrc/view/shadowsocksr/ssrurl.htm              （vless:// reality 分享链接导入）
#        root/usr/share/shadowsocksr/subscribe.lua        （订阅解析）
#        root/usr/share/shadowsocksr/gen_config.lua       （生成 realitySettings 段）
#      对照：reality 首次入库是 8fc1f6a(2023-03-11)，分享链接支持是 2c9d29d(2023-03-25)，
#      a201839 远晚于两者，功能完整。
#   2) 体积最优 —— 官方 mips32le release 对比：
#        v1.8.4 = 18.19MiB < v1.8.8 = 20.01MiB < v24.12.31 = 21.11MiB < v26.10.29 = 23.54MiB
#      strip 进 squashfs 后约 4.8MiB vs 7.5MiB，正好是小闪存能不能装下的分水岭。
#   3) xray v1.8.4 的 go.mod 要求 Go 1.20/1.21 → diy-golang.sh 对本机型降到 Go 1.22，
#      比 master 线要求的 Go 1.26 更省宿主编译时间（且 1.22 编出的二进制更小）。
#
# ⚠️ 若你的服务端用到 XHTTP/splithttp 等新传输，或 reality 连接异常，
#    把下面 PIN_COMMIT 改成空串（走 master 最新）；但注意本机型已在 config 里
#    关闭整条 USB 链（无 extroot 退路），走 master 最新 xray 会撑爆 16MB 分区，
#    届时必须同时把 USB 那几个包回开才有可行解。
SMALL_FLASH_PATTERNS="*a3004ns*"
PIN_COMMIT="a201839"

if [ -n "$SMALL_FLASH_PATTERNS" ] && [ -n "$PIN_COMMIT" ]; then
  for pat in $SMALL_FLASH_PATTERNS; do
    case "$TARGET_CONFIG" in
      $pat)
        echo "==> 小闪存机型（$TARGET_CONFIG）：pin helloworld 到 $PIN_COMMIT（xray v1.8.4，reality 完整可用）"
        if git -C package/helloworld checkout -q "$PIN_COMMIT"; then
          echo "==> 已切换到 $(git -C package/helloworld log -1 --format='%h %ad %s' --date=short)"
        else
          echo "!! 错误：checkout $PIN_COMMIT 失败，固件将用 master 最新（体积可能超 16MB）"
          exit 1
        fi
        PINNED=1
        break
        ;;
    esac
  done
fi

if [ -z "${PINNED:-}" ]; then
  case "$SRC_BRANCH" in
    openwrt-18.06-k*) echo "==> 18.06-k5.4：用 helloworld master 最新提交（xray v26.x 需 Go 1.26）" ;;
    *)                echo "==> 23.05/master：用 helloworld master 分支最新提交（ssr-plus 190-3；Rust 已在下方剥离）" ;;
  esac
fi

echo "==> 剥离 shadowsocks-rust（Rust 工具链在 aarch64/filogic 上编译极慢；ssr-plus 用 shadowsocks-libev 版即可，去掉 Rust 不影响 SSR/V2Ray/Xray 单出口，且 kst-wf3000a 等机型不再被拖慢）"
SSRP_MK="package/helloworld/luci-app-ssr-plus/Makefile"
if [ -f "$SSRP_MK" ]; then
  # aarch64 上 INCLUDE_Shadowsocks_Rust_Client 默认 y，并通过 DEPENDS 条件依赖
  #   +PACKAGE_$(PKG_NAME)_INCLUDE_Shadowsocks_Rust_Client:shadowsocks-rust-sslocal
  # 强制拽入 Rust（shadowsocks-rust 1.24.0 要求 rustc 1.88，编译极慢且易失败）。
  # 该写法既不是 select 也不是 +shadowsocks-rust，旧 sed 漏匹配；故直接删除所有含
  # shadowsocks-rust 的依赖行（覆盖 select / +PKG:shadowsocks-rust-xxx 等任意写法）。
  # 删后即便 INCLUDE_Shadowsocks_Rust_Client=y 也不再拉 Rust 子包，ssr-plus 改走 libev 版。
  sed -i '/shadowsocks-rust/d' "$SSRP_MK"
  echo "==> 已剥离 shadowsocks-rust（INCLUDE_Shadowsocks_Rust_*=n 现在才真正生效，aarch64 不再编译 Rust）"
else
  echo "!! 未找到 $SSRP_MK，跳过 Rust 剥离（请确认 helloworld 源已就位）"
fi

# 自检：确认 xray-core 版本与 ssr-plus 存在
XRAY_VER=$(grep -m1 'PKG_VERSION:=' package/helloworld/xray-core/Makefile 2>/dev/null | cut -d'=' -f2)
echo "==> xray-core 当前锁定版本：v${XRAY_VER:-未知}"
if [ -z "$XRAY_VER" ]; then
  echo "!! 警告：未能读取 xray-core 版本，固件可能仍过大"
fi

# 小闪存机型体积复核：xray 主版本必须落在 1.8.x，否则 16MB 放不下
if [ -n "${PINNED:-}" ]; then
  case "$XRAY_VER" in
    1.8.*) echo "==> 体积检查通过：xray v$XRAY_VER 进 squashfs 约 4.8MiB，符合 16MB 预算" ;;
    *)     echo "!! 错误：pin 未生效（xray=$XRAY_VER），超出 16MB 预算，已中止"; exit 1 ;;
  esac
fi
