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
# 当前编译机型（由 build.yml 经 env 传入，形如 dw33d.config）；用于按机型决定 helloworld 版本策略：
#   大闪存机型(dw33d 128MB)用 master 最新；小闪存机型(k2p 等 16MB)保持旧 pin 把 xray 压在 v1.8.24。
DEVICE_TARGET="${DEVICE_TARGET:-}"
DEVICE="${DEVICE_TARGET%.config}"        # 去掉 .config 后缀，得纯设备名（dw33d / k2p）
# 分支隔离：仅「真正的老 18.06（openwrt-18.06，4.x 内核）」跳过 helloworld master 源；
# openwrt-18.06-k5.4 是「18.06 包基础 + 5.4 新内核」，兼容 helloworld / ngrokc / frpc，放行。
case "$SRC_BRANCH" in
  openwrt-18.06-k*) : ;;                         # 18.06 + 新内核(k5.4)：放行 helloworld
  openwrt-18.06) echo "==> 旧版 18.06(老内核 4.x)，跳过 helloworld master 源（不兼容）"; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# 分支策略（按 SOURCE_BRANCH 选 helloworld 版本）：
#   - 18.06-k5.4：按机型区分——
#       · 小闪存机型(k2p 等 16MB)：checkout 到旧 commit 24a191c（ssr-plus 188 / xray v1.8.24，4MB 装得进 16MB）；
#       · 大闪存机型(dw33d 128MB)：不 pin，用 master 最新（ssr-plus 190-3+ / xray v26.5.9，
#         xray 源码编译需 Go 1.26，由 diy-golang.sh 对 dw33d 升 Go 1.26）。
#   - 23.05 / master：用 helloworld 的 master 分支（非默认 dev 分支）。fw876/helloworld 的
#       DEFAULT 分支是 dev（ssr-plus 196-7），但用户要的是 master 分支（ssr-plus 190-3）。
#       clone 必须显式 -b master，否则会误拉 dev。xray-core 随 master 走（v25/v26，Go 1.26）。
# 全量 clone（非浅克隆）：后续 18.06 需 git checkout 历史 commit，浅克隆不可靠。
# ---------------------------------------------------------------------------
# HELLOWORLD_PIN_COMMIT：仅「小闪存 18.06-k5.4 机型」(k2p 等 16MB) checkout 到该旧 commit，
# 把 xray 压在 v1.8.24(4MB) 才塞得进 16MB；大闪存机型(dw33d 128MB)不 pin，直接用 master 最新。
HELLOWORLD_PIN_COMMIT="24a191cedb8ce45dc07343544a78ef2369c68098"

echo "==> 添加 luci-app-ssr-plus 源（fw876/helloworld，clone 到 package/helloworld）"
rm -rf package/helloworld
# 全量 clone，并显式 -b master：fw876/helloworld 的 DEFAULT 分支是 dev（ssr-plus 196-7），
# 不指定分支会误拉 dev，必须用 -b master 拿 ssr-plus 190-3 的版本。
git clone -b master https://github.com/fw876/helloworld.git package/helloworld
if [ ! -d "package/helloworld/luci-app-ssr-plus" ]; then
  echo "!! 错误：helloworld clone 未包含 luci-app-ssr-plus，请检查网络/源可用性"
  exit 1
fi
echo "==> helloworld 已就绪，luci-app-ssr-plus 来自：package/helloworld/luci-app-ssr-plus"

cd package/helloworld
# 18.06-k5.4 按机型区分 helloworld 版本：
#   - dw33d(128MB NAND)：直接采用 clone 的 master 最新提交（ssr-plus 190-3+ / xray v26.5.9），
#     用户要求追最新；xray v26.5.9 源码编译需 Go 1.26，diy-golang.sh 已对 dw33d 升到 1.26。
#   - 其它 18.06-k5.4 小闪存机型(k2p 等)：checkout 旧 pin（ssr-plus 188 / xray v1.8.24），
#     把 xray 压在 4MB 才塞得进 16MB，保持原行为不破坏。
#   - 23.05 / master：本就用 master 最新。
case "$SRC_BRANCH" in
  openwrt-18.06-k*)
    if [ "$DEVICE" = "dw33d" ]; then
      echo "==> 18.06-k5.4 (dw33d, 128MB NAND)：用 helloworld master 最新提交（xray v26.5.9 需 Go 1.26）"
    else
      echo "==> 18.06-k5.4 ($DEVICE 小闪存)：checkout 旧 pin $HELLOWORLD_PIN_COMMIT（ssr-plus 188 / xray v1.8.24）"
      git checkout "$HELLOWORLD_PIN_COMMIT"
    fi
    ;;
  *)
    echo "==> 23.05/master：用 helloworld master 分支最新提交（ssr-plus 190-3；Rust 已在下方剥离）"
    ;;
esac
cd ../..

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
# 回退后目录会变 dirty（对比原 clone 的 master tip），但构建只扫描源码，无影响；
# 仅提示，不阻断。
if [ -z "$XRAY_VER" ]; then
  echo "!! 警告：未能读取 xray-core 版本，固件可能仍过大"
fi
