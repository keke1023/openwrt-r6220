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
#        v1.8.4 = 18.19MiB < v1.8.8 = 20.01MiB < v24.12.31 = 21.11MiB
#        < v1.8.24 = 21.28MiB < v26.10.29 = 23.54MiB
#      strip 进 squashfs 后约 4.8MiB vs 7.5MiB，正好是小闪存能不能装下的分水岭。
#      （pin 到 a201839 后，下方还会把 xray-core 单独前移到 1.8 系最终版 v1.8.24，
#        换取 REALITY/Vision 的 bug 修复，代价约 +0.8MiB。）
#   3) xray v1.8.4 的 go.mod 要求 Go 1.20/1.21 → diy-golang.sh 对本机型降到 Go 1.22，
#      比 master 线要求的 Go 1.26 更省宿主编译时间（且 1.22 编出的二进制更小）。
#
# ⚠️ 若你的服务端用到 XHTTP/splithttp 等新传输，或 reality 连接异常，
#    把下面 PIN_COMMIT 改成空串（走 master 最新）；但注意本机型已在 config 里
#    关闭整条 USB 链（无 extroot 退路），走 master 最新 xray 会撑爆 16MB 分区，
#    届时必须同时把 USB 那几个包回开才有可行解。
# 16MB SPI NOR 机型清单（**精确匹配 config 基名**，不用通配）：
#   a3004ns-dual.config —— 纯有线（无线全关）
#   k2p.config          —— 带开源 mt76 无线（mt7615e），比 a3004ns 更吃紧，同样必须 pin
#   ezviz_cs-w3-wd1200g.config —— 萤石 W3 原厂 16MB（ipq40xx / IPQ4018 + 128MB RAM）。
#       注意与 23.05 的 ezviz_cs-w3-wd1200g-32m.config（已换 32MB 芯片）区分：
#       这里只 pin 原厂 16MB 那个，32m 版仍走 master 最新。
#   wr1200js.config     —— 友华 WR1200JS（ramips/mt7621，16MB SPI NOR / 128MB DDR3）。
#       开源 mt76 双芯片：MT7603E(2.4G) + MT7612E(5G)，上游本来就是开源驱动，无闭源可换。
#       相对 k2p 少了 mt7615 的独立 firmware 包、且去掉了 dropbear/opkg，但同属 16MB 档，
#       必须一起 pin（走 master 最新 xray v26 会直接撑爆 15.7MiB 的 firmware 分区）。
# ⚠️ 这里必须写精确名：早期写成 *k2p*，会把 23.05 的 phicomm_k2p-32m.config（32MB，
#    本来该走 master 最新 xray）一起 pin 到 a201839 + 旧 xray，属于误伤。
SMALL_FLASH_PATTERNS="a3004ns-dual.config k2p.config ezviz_cs-w3-wd1200g.config wr1200js.config"
PIN_COMMIT="a201839"

if [ -n "$SMALL_FLASH_PATTERNS" ] && [ -n "$PIN_COMMIT" ]; then
  for pat in $SMALL_FLASH_PATTERNS; do
    case "$TARGET_CONFIG" in
      $pat)
        echo "==> 小闪存机型（$TARGET_CONFIG）：pin helloworld 到 $PIN_COMMIT（luci 保持 reality 完整），xray 随后前移到 v1.8.24"
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

# ---------------------------------------------------------------------------
# 小闪存机型：把 xray-core 单独前移到 1.8 系最终版 v1.8.24（2024-08-30）
#
# 为什么只换 xray、不动 luci：a201839 这套 luci-app-ssr-plus 的 reality/vision
# 字段已齐全、18.06 的 Lua CBI 也能跑；换 luci 会引入 luci-compat / nftables 等
# 新依赖，风险远大于收益。所以 pin 住 luci，只改 xray-core 的版本与哈希。
#
# 体积实测（官方 mips32le release zip，与 squashfs 压缩率同源可比）：
#   v1.8.4 = 18.19MiB → v1.8.8 = 20.01MiB → v1.8.24 = 21.28MiB（+17%）
#   折算 squashfs 里约 4.8MiB → 5.6MiB，镜像约 +0.8MiB，
#   即 13057k → 约 13880k，overlay 由 3.0MiB 降到约 2.2MiB。
#   仍在 16128k 预算内，但余量不多：刷完不要再追加合计超过 0.5MiB 的包。
# go.mod 要求 go 1.21.4，本机型用 Go 22.x（sbwml golang 22.x 分支）满足。
# ---------------------------------------------------------------------------
XRAY_MK="package/helloworld/xray-core/Makefile"
XRAY_PIN_VER="1.8.24"
XRAY_PIN_HASH="86e3e388c77cda4d8457a607356416c201c1f18bbed53f0a9e76a228508ff298"
# 2026-11-03 起萤石也前移 1.8.24：实测（K2P 固件解包 vs 萤石 V6 固件解包）
#   xray 1.8.4 squashfs 内压缩 3,940 KiB → 1.8.24 为 4,181 KiB，仅 +241 KiB，
#   镜像 13312k → 约 13553k（预算 14336k，余 ~783k），overlay 1536k → 约 1295k。
#   1.8.24 带来 Vision 断连修复 / XUDP 走 Vision / REALITY CloseWrite，值得。
if [ -n "${PINNED:-}" ] && [ -f "$XRAY_MK" ]; then
  XRAY_CUR=$(grep -m1 '^PKG_VERSION:=' "$XRAY_MK" | cut -d'=' -f2)
  if [ "$XRAY_CUR" = "$XRAY_PIN_VER" ]; then
    echo "==> xray-core 已是 v$XRAY_PIN_VER，跳过版本前移"
  else
    sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$XRAY_PIN_VER/" "$XRAY_MK"
    sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$XRAY_PIN_HASH/" "$XRAY_MK"
    echo "==> xray-core 版本前移：v${XRAY_CUR:-?} -> v$XRAY_PIN_VER（1.8 系最终版）"
    if ! grep -q "^PKG_VERSION:=$XRAY_PIN_VER" "$XRAY_MK" || \
       ! grep -q "^PKG_HASH:=$XRAY_PIN_HASH" "$XRAY_MK"; then
      echo "!! 错误：xray-core Makefile 的版本/哈希替换失败，请人工检查 $XRAY_MK"
      exit 1
    fi
  fi
  grep -E '^PKG_(VERSION|HASH):' "$XRAY_MK" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# xray 二进制精简（按版本自动选补丁集；仅小闪存机型 PINNED 生效）
# ---------------------------------------------------------------------------
# v3 改用 OpenWrt 标准 patches 机制：把 unified diff 放进
# package/helloworld/xray-core/patches/，由 Build/Patch（PATCH_DIR=./patches）
# 在 Prepare 阶段无条件应用。补丁源按 xray 版本分目录存放（1.8.4 / 1.8.24），
# 由 patch-xray-slim.py 读 PKG_VERSION 自动选择 —— 两版源码结构不同，
# 1.8.4 那套直接喂给 1.8.24 会 11 个文件全部 reject（实测）。
#
#   1.8.4（萤石 W3，原厂 16MB）4 个补丁：
#     001 删 all.go 12 个空导入
#     002 删 all.go 4 个 gRPC API 模块 + CLI 的 api 子命令
#     003 grpc 全链：掏空 tls/grpc.go（★ tls 为 reality 必须保留，但它自己
#         import grpc 的 NewGrpcUtls，不掏空它 grpc 永远退不出去，实测只省 37 KB）
#         + 掏空 conf/{grpc,api}.go（★ conf 的 api 段 import commander，这才是
#         grpc-go 常驻的真因）+ 删 TransportConfig/StreamConfig/xray.go 字段与 Build
#     004 wireguard/gvisor（gvisor 全仓只被 proxy/wireguard 引用）+ QUIC 传输
#         + DoQ + QUIC 嗅探
#
#   1.8.24（K2P / WR1200JS / a3004ns-dual）5 个补丁：结构同上，但
#     005 必须额外砍掉 splithttp —— 它自带 HTTP/3（quic-go/http3），是
#     quic-go 的第四个入口，不砍它 quic-go 会从这条路重新被链进来。
#
# 为什么不再覆盖 Build/Prepare：v1/v2 两轮 CI 产出的 xray 二进制 md5 完全相同
# （23,713,500 B），grpc / commander / quic-go 全在，证明那个 hook 压根没被执行。
#
# 保留 vless(in/outbound) + reality + tls + tcp + udp + websocket + http +
# httpupgrade + vmess + shadowsocks + trojan + socks + dokodemo + freedom，
# vless+reality+vision 完整可用；SS/SSR 走 shadowsocks-libev 独立二进制。
#
# 门控：只在 PINNED（小闪存机型）生效。萤石 16MB 已实测可启动且
# vless+reality+vision 正常工作（overlay 1216 KiB）；K2P / WR1200JS 走 1.8.24 那套。
# 32MB 改造机型（phicomm_k2-32m / ezviz *-32m）不在 PINNED 里，不精简。
if [ -n "${PINNED:-}" ]; then
  XRAY_SLIM_PY="../scripts/patch-xray-slim.py"
  XRAY_SLIM_PKG="package/helloworld/xray-core"
  if [ -f "$XRAY_SLIM_PY" ] && [ -d "$XRAY_SLIM_PKG" ]; then
    python3 "$XRAY_SLIM_PY" "$XRAY_SLIM_PKG" || { echo "!! 错误：xray 精简补丁落位失败"; exit 1; }
    echo "==> xray-core/patches 内容："
    ls -1 "$XRAY_SLIM_PKG/patches" | sed 's/^/       /'
  else
    echo "!! 警告：缺少 $XRAY_SLIM_PY 或 $XRAY_SLIM_PKG，跳过 xray 精简（固件可能超分区）"
  fi
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

# ---------------------------------------------------------------------------
# ssr-plus 的协议依赖：**保持完整**（2026-11-01 回滚此前的瘦身）
# ---------------------------------------------------------------------------
# 187-2 的 LUCI_DEPENDS 里有一串**无条件** + 依赖，与是否启用对应协议无关：
#     +dns2socks +dns2tcp +microsocks +shadowsocksr-libev-ssr-check
# 上一版为了省 ~100KB 用 sed 把它们删了；现在恢复，原因：
#   - ss 协议仍可能用到，而 dns2socks / dns2tcp 正是 ss 节点的 UDP-DNS 转发后端
#     （xray 走内置 DNS，ss 走这两个二进制）；
#   - microsocks 是「局域网共享」入口，ssr-check 是节点连通性检测；
#   - 删掉后 UI 上仍显示这些选项，点了没反应 —— 功能残缺比省 100KB 更难受。
# 这四项安装体积合计约 100KB，进 squashfs 约 35KB，不值得为此破坏功能完整性。
# 若将来确实要再瘦：把下面 echo 换成
#   sed -i -E 's/\+dns2socks\b//g; s/\+dns2tcp\b//g; s/\+microsocks\b//g; s/\+shadowsocksr-libev-ssr-check\b//g' "$SSRP_MK"
if [ -f "$SSRP_MK" ]; then
  echo "==> ssr-plus 协议依赖（保持完整，不做剥离）："
  sed -n '/^LUCI_DEPENDS:=/,/^$/p' "$SSRP_MK" | sed 's/^/    /'
fi

# ---------------------------------------------------------------------------
# K2P：无线走开源 mt76 —— 先确认本分支自带该包（不满足就别继续，白烧一小时编译）
# ---------------------------------------------------------------------------
# 事实依据（已核对 immortalwrt openwrt-18.06-k5.4）：
#   package/kernel/mt76/Makefile  PKG_SOURCE_DATE:=2021-10-23.1
#   其 Makefile 内定义了 KernelPackage/mt76-core、mt76-connac、mt7615-common、
#   mt7615e、mt7615-firmware；patches 只有一个 001-allow-vht-on-2g.patch（正是给
#   MT7615 的 2.4G VHT 用的）。因此**不需要从 21.02 搬源码**，只需改 DEVICE_PACKAGES
#   与 config（见 diy-part2.sh 第 [18] 段）。
case "$TARGET_CONFIG" in
  *k2p*)
    echo "==> K2P：校验本分支自带的开源 mt76 包"
    MT76_MK="package/kernel/mt76/Makefile"
    if [ ! -f "$MT76_MK" ]; then
      echo "!! 错误：$MT76_MK 不存在 —— 本分支没有 mt76，需要另行搬运（原计划从 21.02 取）"
      exit 1
    fi
    for sym in mt7615e mt7615-common mt7615-firmware mt76-core mt76-connac; do
      if ! grep -q "KernelPackage/$sym\$" "$MT76_MK"; then
        echo "!! 错误：$MT76_MK 里没有 KernelPackage/$sym，开源无线方案不成立"
        exit 1
      fi
    done
    echo "    OK：kmod-mt7615e / mt7615-common / mt7615-firmware / mt76-core / mt76-connac 齐备"
    echo "    mt76 版本：$(grep -m1 '^PKG_SOURCE_DATE:=' "$MT76_MK" | cut -d= -f2)"
    ;;
  *wr1200js*)
    # WR1200JS：上游 DEVICE_PACKAGES 就是 kmod-mt7603 + kmod-mt76x2（开源），
    #   不需要像 K2P 那样换驱动，但要确认本分支的 mt76 里确实定义了这两个包
    #   —— 少了任一 kmod，固件会「能开机、没 wifi」，而且不报错。
    echo "==> WR1200JS：校验本分支自带的开源 mt76 包（mt7603 + mt76x2）"
    MT76_MK="package/kernel/mt76/Makefile"
    if [ ! -f "$MT76_MK" ]; then
      echo "!! 错误：$MT76_MK 不存在 —— 本分支没有 mt76，开源无线方案不成立"
      exit 1
    fi
    for sym in mt7603 mt76x2 mt76x2-common mt76-core; do
      if ! grep -q "^define KernelPackage/$sym\$" "$MT76_MK"; then
        echo "!! 错误：$MT76_MK 里没有 define KernelPackage/$sym，开源无线方案不成立"
        exit 1
      fi
    done
    echo "    OK：mt7603 / mt76x2 / mt76x2-common / mt76-core 齐备"
    echo "    mt76 版本：$(grep -m1 '^PKG_SOURCE_DATE:=' "$MT76_MK" | cut -d= -f2)"
    ;;
esac


# 自检：确认 xray-core 版本与 ssr-plus 存在
XRAY_VER=$(grep -m1 'PKG_VERSION:=' package/helloworld/xray-core/Makefile 2>/dev/null | cut -d'=' -f2)
echo "==> xray-core 当前锁定版本：v${XRAY_VER:-未知}"
if [ -z "$XRAY_VER" ]; then
  echo "!! 警告：未能读取 xray-core 版本，固件可能仍过大"
fi

# ---------------------------------------------------------------------------
# 187-2 + xray v1.8.24 专项修复：三处「导入一份订阅，整条代理全挂」的隐患
#
# 187-2（a201839）是完整支持 vless+reality+vision 的最老版本，但它不认两个
# 2024 年后才在订阅里普及的写法。这两处失败方式特别恶劣：不是单个节点失效，
# 而是 xray 解析 config.json 直接报错退出 → ssr-plus 拉起失败 → 所有节点全不可用。
#
#  [A] transport=raw —— 新版 xray 把 tcp 传输改名为 raw，v2rayN 与机场订阅随之
#      开始下发 type=raw。187-2 只认 tcp，原样写进 config 就是 network="raw"，
#      而 v1.8.24 的传输枚举里没有 raw（raw 是 v24.9+ 才引入的），
#      报 `unknown transport protocol: raw`。
#      → 订阅解析处归一（顺带让 tcp_guise/headerType 分支能正确命中，否则
#        http 伪装的 headerType 会被静默丢掉）；gen_config.lua 读入 server 后
#        再兜一层，覆盖 vmess 分享链接、手工 UI 配置、历史已存进 uci 的旧节点。
#
#  [B] flow=none —— vless 的 flow 合法值只有 ""/"xtls-rprx-vision"，"none" 会
#      触发 `unknown flow: none`，同样整份配置拒绝启动。
#      本机 UI 无此风险：client-config.lua 的 tls_flows 只有 xtls-rprx-vision /
#      xtls-rprx-vision-udp443 两项，表单根本选不出 none —— 所以 none 只可能
#      从订阅链接进来。
#      → 订阅入库前剔除，gen_config.lua 出口再剔一次。
#
# 为什么限定 PINNED（=16MB 小闪存=187-2+xray v1.8.24）才打：master 线
#   （190-3 + xray v26）里 raw 是合法传输名，把 raw 改回 tcp 等于主动降级新特性，
#   反而有害。本补丁只服务「老 luci 撞上新订阅」这个组合。
# ---------------------------------------------------------------------------
if [ -n "${PINNED:-}" ]; then
  SSRP_DIR="package/helloworld/luci-app-ssr-plus/root/usr/share/shadowsocksr"
  GEN_CFG="$SSRP_DIR/gen_config.lua"
  SUB_LUA="$SSRP_DIR/subscribe.lua"
  echo "==> 187-2 订阅兼容补丁：transport raw→tcp / 剔除 flow=none"
  MISSING=0
  for f in "$GEN_CFG" "$SUB_LUA"; do
    [ -f "$f" ] || { echo "!! 错误：未找到 $f，补丁无处落地"; MISSING=1; }
  done
  [ "$MISSING" = "1" ] && exit 1

  # [A-1] 订阅链接 type=raw → tcp
  grep -q 'result.transport = (params.type == "raw")' "$SUB_LUA" || \
    sed -i 's|result.transport = params.type or "tcp"|result.transport = (params.type == "raw") and "tcp" or (params.type or "tcp")|' "$SUB_LUA"

  # [A-2] gen_config 兜底归一：插在 server 读入之后，后续所有 transport 判断自动受益
  grep -q 'server.transport == "raw" then server.transport = "tcp"' "$GEN_CFG" || \
    sed -i '/^local server = ucursor:get_all("shadowsocksr", server_section)/a if server.transport == "raw" then server.transport = "tcp" end' "$GEN_CFG"

  # [B-1] 订阅里 flow=none / 空串 不入库
  grep -q 'params.flow ~= "none"' "$SUB_LUA" || \
    sed -i 's|result.tls_flow = (params.security == "tls" or params.security == "reality") and params.flow or nil|result.tls_flow = ((params.security == "tls" or params.security == "reality") and params.flow ~= "none" and params.flow ~= "") and params.flow or nil|' "$SUB_LUA"

  # [B-2] gen_config 出口再剔一次
  grep -q 'server.tls_flow ~= "none"' "$GEN_CFG" || \
    sed -i 's|flow = ((server\.tls == .1.) or (server\.reality == .1.)) and server\.tls_flow or nil|flow = (((server.tls == "1") or (server.reality == "1")) and server.tls_flow ~= "none" and server.tls_flow ~= "") and server.tls_flow or nil|' "$GEN_CFG"

  # 回读校验：sed 静默不匹配是这套流程最大的坑（照常 exit 0，却编出一版没补丁的固件）
  PATCH_FAIL=0
  grep -q 'result.transport = (params.type == "raw")' "$SUB_LUA" || { echo "!! [A-1] subscribe raw→tcp 未生效"; PATCH_FAIL=1; }
  grep -q 'server.transport == "raw" then server.transport = "tcp"' "$GEN_CFG" || { echo "!! [A-2] gen_config raw 归一未生效"; PATCH_FAIL=1; }
  grep -q 'params.flow ~= "none"' "$SUB_LUA" || { echo "!! [B-1] 订阅 flow=none 未剔除"; PATCH_FAIL=1; }
  grep -q 'server.tls_flow ~= "none"' "$GEN_CFG" || { echo "!! [B-2] 出口 flow=none 未剔除"; PATCH_FAIL=1; }
  if [ "$PATCH_FAIL" = "1" ]; then
    echo "!! 错误：订阅兼容补丁未全部落地，中止 —— 否则会编出「一导入订阅全网就断」的固件"
    exit 1
  fi

  # 有 luac 顺带做语法校验（luci 是 Lua 5.1 语法）
  for LC in luac luac5.1; do
    if command -v "$LC" >/dev/null 2>&1; then
      "$LC" -p "$GEN_CFG" && "$LC" -p "$SUB_LUA" || { echo "!! 错误：补丁后 Lua 语法不通过"; exit 1; }
      echo "    Lua 语法校验通过（$LC -p）"
      break
    fi
  done
  echo "    已打补丁：raw→tcp（订阅+出口双层）、flow=none 剔除（订阅+出口双层）"
fi

# 小闪存机型体积复核：xray 主版本必须落在 1.8.x，否则 16MB 放不下
if [ -n "${PINNED:-}" ]; then
  case "$XRAY_VER" in
    1.8.*) echo "==> 体积检查通过：xray v$XRAY_VER 进 squashfs 约 4.8~5.6MiB，符合 16MB 预算" ;;
    *)     echo "!! 错误：pin 未生效（xray=$XRAY_VER），超出 16MB 预算，已中止"; exit 1 ;;
  esac
fi
