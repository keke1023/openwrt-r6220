#!/bin/bash
# HNAT-P1: 在 ./scripts/feeds update/install 之前运行（当前位于 openwrt 源码根目录）
#
# 本脚本只服务「padavanonly/immortalwrt @ master + MT7621 硬件 NAT」这一条线，
# 与 scripts/diy-part1.sh（18.06-k5.4 / 23.05 主线的 ssr-plus 线）互不干扰。
# 由 build.yml 按 matrix.cfgdir == config-hnat 选择执行。
#
# 做的四件事：
#   1) 断言源码确实是 padavanonly 分支（含 mediateksdk + hnat dts），否则立刻中止
#   2) helloworld pin 到 a201839（luci-app-ssr-plus 187-2）
#   3) xray-core 单独前移到 1.8 系最终版 v1.8.24
#   4) 打 187-2 订阅兼容补丁（transport=raw / flow=none 双层拦截）
#
# 为什么不复用 diy-part1.sh：
#   那边有大量 18.06 分支专属逻辑（openwrt-18.06-k* 判断、mt76 KernelPackage 校验、
#   k2p 分支特判）。本线分支名就是 master，会误落进「大闪存走 master 最新」分支，
#   导致 xray 变成 v26（单项 7.5MiB）直接撑爆 16MB。与其在主脚本里堆 if，
#   不如独立成文件，两条线各自演进、互不牵连。

TARGET_CONFIG="${TARGET_CONFIG:-}"

# ---------------------------------------------------------------------------
# 前置断言 1：确认是 padavanonly/immortalwrt（MTK SDK 以太网驱动）
#
# mediateksdk 是这套源码区别于官方 openwrt/immortalwrt 的唯一标志 —— 官方树里
# 没有这个目录（官方走 drivers/net/ethernet/mediatek/mtk_eth_soc.c）。
# 缺了它，说明 source_repo 配错，后面所有 hnat 相关的假设全部不成立，
# 与其编一小时出一版没有硬件加速的固件，不如现在就退出。
# ---------------------------------------------------------------------------
SDK_DIR="target/linux/ramips/files/drivers/net/ethernet/mediateksdk"
if [ ! -f "$SDK_DIR/Kconfig" ]; then
  echo "!! 错误：未找到 $SDK_DIR/Kconfig"
  echo "!!       当前源码不是 padavanonly/immortalwrt —— 该分支才有 MTK SDK 驱动与 HNAT"
  echo "!!       请检查 build.yml 的 source_repo 是否指向 padavanonly/immortalwrt"
  exit 1
fi
echo "==> 源码校验通过：发现 mediateksdk（MTK SDK 以太网驱动）"

# ---------------------------------------------------------------------------
# 前置断言 2：mt7621.dtsi 必须有 hnat 节点
# 节点的 compatible 是 "mediatek,mtk-hnat_v1"，reg 0x1e100000 0x3000（MT7621 的 PPE 基址）。
# hnat-part2.sh 会把它从 status="disabled" 改成 okay；这里先确认它确实存在。
# ---------------------------------------------------------------------------
if ! grep -q 'mediatek,mtk-hnat_v1' target/linux/ramips/dts/mt7621.dtsi; then
  echo "!! 错误：mt7621.dtsi 里没有 mediatek,mtk-hnat_v1 节点 —— 本分支不支持 MT7621 HNAT"
  exit 1
fi
echo "==> dts 校验通过：mt7621.dtsi 含 hnat@1e100000 (mtk-hnat_v1)"

# ---------------------------------------------------------------------------
# 1) helloworld → package/helloworld，并 pin 到 a201839
#
# 为什么用 clone 而不是 feeds 追加：见 diy-part1.sh 开头说明（feeds 拉取被限流时
# 会静默失败，导致实际编出官方 luci 源里的 ssr-plus）。clone 到 package/ 下优先级最高。
#
# a201839 = 2023-10-15，luci-app-ssr-plus 187-2，是**完整支持 vless+reality+vision
# 的最老版本**，也是 16MB 分区能装下的版本（配套 xray 1.8.x）。
# ---------------------------------------------------------------------------
PIN_COMMIT="a201839"
echo "==> 添加 luci-app-ssr-plus 源（fw876/helloworld，clone 到 package/helloworld）"
rm -rf package/helloworld
git clone -b master https://github.com/fw876/helloworld.git package/helloworld
if [ ! -d "package/helloworld/luci-app-ssr-plus" ]; then
  echo "!! 错误：helloworld clone 未包含 luci-app-ssr-plus，请检查网络/源可用性"
  exit 1
fi

echo "==> pin helloworld 到 $PIN_COMMIT（ssr-plus 187-2）"
if git -C package/helloworld checkout -q "$PIN_COMMIT"; then
  echo "    已切换到 $(git -C package/helloworld log -1 --format='%h %ad %s' --date=short)"
else
  echo "!! 错误：checkout $PIN_COMMIT 失败 —— 固件将用 master 最新版（xray 体积可能超 16MB）"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2) 剥离 shadowsocks-rust
#
# 187-2 的 LUCI_DEPENDS 里带 +shadowsocks-rust（aarch64 上默认 y），会把 Rust
# 工具链拖进来：编得极慢、易失败、体积也大。删掉依赖行后 ssr-plus 自动改用 libev 版。
# ---------------------------------------------------------------------------
SSRP_MK="package/helloworld/luci-app-ssr-plus/Makefile"
if [ -f "$SSRP_MK" ]; then
  sed -i '/shadowsocks-rust/d' "$SSRP_MK"
  echo "==> 已剥离 shadowsocks-rust 依赖（改走 libev 客户端）"
else
  echo "!! 错误：$SSRP_MK 不存在"
  exit 1
fi

# ---------------------------------------------------------------------------
# 3) xray-core → v1.8.24（1.8 系最终版）
#
# 187-2 自带 xray 1.8.4；前移到 1.8.24 换取 REALITY/Vision 一年多的 bug 修复。
# 官方 mips32le release 体积：v1.8.4 = 18.19MiB → v1.8.24 = 21.28MiB（+17%），
# 进 squashfs 约 4.8 → 5.6MiB，镜像约 +0.8MiB。
#
# 为什么不升到 v24.12/v26：raw 传输名与新版行为差异大，且 v26 单项 7.5MiB，
# 16MB 分区放不下（这正是 hnat 线仍走 187-2 的原因）。
# go.mod 要求 go 1.21.4 → diy-golang.sh 对 *a3004ns* 机型选 Go 22.x。
# ---------------------------------------------------------------------------
XRAY_MK="package/helloworld/xray-core/Makefile"
XRAY_PIN_VER="1.8.24"
XRAY_PIN_HASH="86e3e388c77cda4d8457a607356416c201c1f18bbed53f0a9e76a228508ff298"
if [ ! -f "$XRAY_MK" ]; then
  echo "!! 错误：$XRAY_MK 不存在"
  exit 1
fi
XRAY_CUR=$(grep -m1 '^PKG_VERSION:=' "$XRAY_MK" | cut -d'=' -f2)
if [ "$XRAY_CUR" = "$XRAY_PIN_VER" ]; then
  echo "==> xray-core 已是 v$XRAY_PIN_VER，跳过版本前移"
else
  sed -i "s/^PKG_VERSION:=.*/PKG_VERSION:=$XRAY_PIN_VER/" "$XRAY_MK"
  sed -i "s/^PKG_HASH:=.*/PKG_HASH:=$XRAY_PIN_HASH/" "$XRAY_MK"
  echo "==> xray-core 版本前移：v${XRAY_CUR:-?} -> v$XRAY_PIN_VER（1.8 系最终版）"
  if ! grep -q "^PKG_VERSION:=$XRAY_PIN_VER" "$XRAY_MK" || \
     ! grep -q "^PKG_HASH:=$XRAY_PIN_HASH" "$XRAY_MK"; then
    echo "!! 错误：xray-core 版本/哈希替换失败，请人工检查 $XRAY_MK"
    exit 1
  fi
fi
XRAY_VER=$(grep -m1 '^PKG_VERSION:=' "$XRAY_MK" | cut -d'=' -f2)
echo "==> xray-core 锁定版本：v$XRAY_VER"

# ---------------------------------------------------------------------------
# 3b) xray 二进制精简（复用仓库既有的 scripts/patch-xray-slim.py）
#
# 必须放在「版本前移」之后：那个脚本是按 PKG_VERSION 选补丁集的（1.8.4 与 1.8.24
# 源码结构不同，1.8.4 的补丁喂给 1.8.24 会 11 个文件全部 reject）。这里版本已锁在
# 1.8.24，脚本会自动取 xray-patches/1.8.24/ 那 5 个补丁：
#   001 删 all.go 的空导入
#   002 删 gRPC API 模块 + CLI api 子命令
#   003 grpc 全链（tls/grpc.go + conf/{grpc,api}.go）
#   004 wireguard/gvisor
#   005 QUIC/HTTP3 —— 含 splithttp 自带的 quic-go/http3 入口，漏了它 quic-go 会被链回来
#
# 保留 vless + reality + tls + tcp/udp + ws + http + httpupgrade + vmess +
# shadowsocks + trojan + socks + dokodemo + freedom —— vless+reality+vision 完整可用。
# 机制：把 diff 放进 xray-core/patches/，靠 OpenWrt 的 Build/Patch 在 Prepare 阶段
# 无条件应用（不是覆盖 Build/Prepare，那个 hook 在实测中被证明不生效）。
# ---------------------------------------------------------------------------
XRAY_SLIM_PY="../scripts/patch-xray-slim.py"
if [ -f "$XRAY_SLIM_PY" ]; then
  echo "==> xray 二进制精简（按 PKG_VERSION=v$XRAY_VER 自动选补丁集）"
  if ! python3 "$XRAY_SLIM_PY" "package/helloworld/xray-core"; then
    echo "!! 错误：xray 精简补丁落位失败"
    exit 1
  fi
  echo "    已落位补丁："
  ls -1 package/helloworld/xray-core/patches 2>/dev/null | sed 's/^/       /'
  # 回读校验：补丁目录必须非空，否则等于没精简（固件体积会明显变大）
  if [ -z "$(ls -A package/helloworld/xray-core/patches 2>/dev/null)" ]; then
    echo "!! 错误：xray-core/patches 为空 —— 精简未生效，16MB 大概率装不下"
    exit 1
  fi
else
  echo "!! 警告：缺少 $XRAY_SLIM_PY，跳过 xray 精简（固件体积会明显变大）"
fi

# ---------------------------------------------------------------------------
# 4) 187-2 订阅兼容补丁（与 18.06 线完全相同的四条，理由见 diy-part1.sh 对应注释）
#
#   [A] transport=raw —— xray v24.9+ 把 tcp 改名 raw，订阅开始下发 type=raw。
#       187-2 只认 tcp，原样写进 config 就是 network="raw"，v1.8.24 报
#       `unknown transport protocol: raw`，整份配置拒绝启动 → 所有节点全挂。
#   [B] flow=none —— vless flow 合法值只有 ""/"xtls-rprx-vision"，none 触发
#       `unknown flow: none`，同样整份配置拒绝启动。
#       本机 UI 选不出 none（client-config.lua 只有两个 vision 选项），只可能来自订阅。
# ---------------------------------------------------------------------------
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

# 回读校验：sed 静默不匹配是这套流程最大的坑（照常 exit 0，却编出没补丁的固件）
PATCH_FAIL=0
grep -q 'result.transport = (params.type == "raw")' "$SUB_LUA" || { echo "!! [A-1] subscribe raw→tcp 未生效"; PATCH_FAIL=1; }
grep -q 'server.transport == "raw" then server.transport = "tcp"' "$GEN_CFG" || { echo "!! [A-2] gen_config raw 归一未生效"; PATCH_FAIL=1; }
grep -q 'params.flow ~= "none"' "$SUB_LUA" || { echo "!! [B-1] 订阅 flow=none 未剔除"; PATCH_FAIL=1; }
grep -q 'server.tls_flow ~= "none"' "$GEN_CFG" || { echo "!! [B-2] 出口 flow=none 未剔除"; PATCH_FAIL=1; }
if [ "$PATCH_FAIL" = "1" ]; then
  echo "!! 错误：订阅兼容补丁未全部落地，中止 —— 否则会编出「一导入订阅全网就断」的固件"
  exit 1
fi

# 有 luac 就顺带做语法校验（luci 是 Lua 5.1 语法；runner 一般没有，纯保险）
for LC in luac luac5.1; do
  if command -v "$LC" >/dev/null 2>&1; then
    "$LC" -p "$GEN_CFG" && "$LC" -p "$SUB_LUA" || { echo "!! 错误：补丁后 Lua 语法不通过"; exit 1; }
    echo "    Lua 语法校验通过（$LC -p）"
    break
  fi
done
echo "    已打补丁：raw→tcp（订阅+出口双层）、flow=none 剔除（订阅+出口双层）"

# ---------------------------------------------------------------------------
# 5) 体积复核：xray 必须落在 1.8.x，否则 16MB 放不下
# ---------------------------------------------------------------------------
case "$XRAY_VER" in
  1.8.*) echo "==> 体积检查通过：xray v$XRAY_VER 进 squashfs 约 5.6MiB，符合 16MB 预算" ;;
  *)     echo "!! 错误：pin 未生效（xray=$XRAY_VER），超出 16MB 预算，已中止"; exit 1 ;;
esac
