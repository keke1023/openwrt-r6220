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
# xray-core 版本锁：helloworld master 当前 xray-core 已涨到 v26.x（Go 1.26 静态二进制
# 约 13MB+），在 16MB SPI 闪存设备(dw33d-spi)上编出来固件 28MB 直接装不下。
# reality 协议自 Xray-core v1.8.0 起即支持，故锁到 helloworld 历史里的 v1.8.7
# （commit bdf6b123cadb776d97cf2d9dd1afb516b046912a，2024-01-08）：体积小（Go 1.20 时代）、
# PKG_HASH 由 helloworld 当时算好可直接用、reality 完全可用。Go 1.26 向下兼容其 1.20 需求。
# 仅回退 xray-core 子目录，ssr-plus Luci 界面与其他 helloworld 包保持 master 最新。
# ---------------------------------------------------------------------------
XRAY_OLD_COMMIT="bdf6b123cadb776d97cf2d9dd1afb516b046912a"

echo "==> 添加 luci-app-ssr-plus 源（fw876/helloworld，clone 到 package/helloworld）"
rm -rf package/helloworld
# 全量 clone（非浅克隆）：后续需 git checkout 历史 commit 的 xray-core 子目录，
# 浅克隆无法可靠取到旧 commit 的树。helloworld 仓库含历史但 runner 空间/网速足够。
git clone https://github.com/fw876/helloworld.git package/helloworld
if [ ! -d "package/helloworld/luci-app-ssr-plus" ]; then
  echo "!! 错误：helloworld clone 未包含 luci-app-ssr-plus，请检查网络/源可用性"
  exit 1
fi
echo "==> helloworld 已就绪，luci-app-ssr-plus 来自：package/helloworld/luci-app-ssr-plus"

echo "==> 回退 xray-core 到 v1.8.7（commit $XRAY_OLD_COMMIT），缩小体积以适配 16MB 闪存"
if [ -d "package/helloworld/xray-core" ]; then
  cd package/helloworld
  git fetch --depth 1 origin "$XRAY_OLD_COMMIT" 2>/dev/null || git fetch origin "$XRAY_OLD_COMMIT"
  git checkout "$XRAY_OLD_COMMIT" -- xray-core/
  cd ../..
  XRAY_VER=$(grep -m1 'PKG_VERSION:=' package/helloworld/xray-core/Makefile | cut -d'=' -f2)
  echo "==> xray-core 当前锁定版本：v$XRAY_VER"
  if [ "$XRAY_VER" != "1.8.7" ]; then
    echo "!! 警告：xray-core 版本回退失败（实际 v$XRAY_VER），固件可能仍过大"
  fi
else
  echo "!! 警告：package/helloworld/xray-core 不存在，跳过版本回退"
fi
