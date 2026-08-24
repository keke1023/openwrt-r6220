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

echo "==> 添加 luci-app-ssr-plus 源（fw876/helloworld，clone 到 package/helloworld）"
rm -rf package/helloworld
git clone --depth 1 https://github.com/fw876/helloworld.git package/helloworld
if [ ! -d "package/helloworld/luci-app-ssr-plus" ]; then
  echo "!! 错误：helloworld clone 未包含 luci-app-ssr-plus，请检查网络/源可用性"
  exit 1
fi
echo "==> helloworld 已就绪，luci-app-ssr-plus 来自：package/helloworld/luci-app-ssr-plus"
