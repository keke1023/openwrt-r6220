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
# 分支隔离：仅「真正的老 18.06（openwrt-18.06，4.x 内核）」跳过 helloworld master 源；
# openwrt-18.06-k5.4 是「18.06 包基础 + 5.4 新内核」，兼容 helloworld / ngrokc / frpc，放行。
case "$SRC_BRANCH" in
  openwrt-18.06-k*) : ;;                         # 18.06 + 新内核(k5.4)：放行 helloworld
  openwrt-18.06) echo "==> 旧版 18.06(老内核 4.x)，跳过 helloworld master 源（不兼容）"; exit 0 ;;
esac

# ---------------------------------------------------------------------------
# 分支策略（按 SOURCE_BRANCH 选 helloworld 版本）：
#   - 18.06-k5.4：整体 checkout 到 coolsnowwolf 2024-09-13 的 commit
#       24a191cedb8ce45dc07343544a78ef2369c68098（即 "xray-core: update to 1.8.24"），
#       ssr-plus 停在 188、xray-core 停在 v1.8.24，适配老内核 + 小闪存。
#   - 23.05 / master：用 helloworld 的 master 分支（非默认 dev 分支）。fw876/helloworld 的
#       DEFAULT 分支是 dev（ssr-plus 196-7），但用户要的是 master 分支（ssr-plus 190-3）。
#       clone 必须显式 -b master，否则会误拉 dev。xray-core 随 master 走（v25/v26，Go 1.26）。
# 全量 clone（非浅克隆）：后续 18.06 需 git checkout 历史 commit，浅克隆不可靠。
# ---------------------------------------------------------------------------
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
case "$SRC_BRANCH" in
  openwrt-18.06-k*)
    echo "==> 18.06-k5.4：整库 checkout 到 $HELLOWORLD_PIN_COMMIT（ssr-plus 188 + xray v1.8.24，老内核/小闪存）"
    git checkout "$HELLOWORLD_PIN_COMMIT"
    ;;
  *)
    echo "==> 23.05/master：用 helloworld master 分支（ssr-plus 190-3；Rust 已在下方剥离）"
    # clone 已显式 -b master 拉取 master 分支，无需再 checkout；整库采用 master 源码
    ;;
esac
cd ../..

echo "==> 剥离 shadowsocks-rust（Rust 工具链在 aarch64/filogic 上编译极慢；ssr-plus 用 shadowsocks-libev 版即可，去掉 Rust 不影响 SSR/V2Ray/Xray 单出口，且 kst-wf3000a 等机型不再被拖慢）"
SSRP_MK="package/helloworld/luci-app-ssr-plus/Makefile"
if [ -f "$SSRP_MK" ]; then
  # aarch64 上 INCLUDE_Shadowsocks_Rust_Client 默认 y，并经 select PACKAGE_shadowsocks-rust 强制拽入 Rust；
  # 光在 seed config 写 =n 关不掉被 select 的选项（defconfig 会翻回），故从源头删掉 select
  sed -i '/select.*shadowsocks-rust/d' "$SSRP_MK"
  # 若 DEPENDS 里存在硬依赖 +shadowsocks-rust / +PACKAGE_shadowsocks-rust 也一并删除（保险）
  sed -i '/+shadowsocks-rust/d' "$SSRP_MK"
  sed -i '/+PACKAGE_shadowsocks-rust/d' "$SSRP_MK"
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
