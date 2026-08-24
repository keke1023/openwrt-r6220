#!/bin/bash
# DIY-P1: 在 ./scripts/feeds update/install 之前运行（当前位于 openwrt 源码根目录）
# 作用：添加第三方软件源。
# 说明：本配置基于 immortalwrt，其官方 feeds 已自带 luci-app-ngrokc、ngrokc、
#       luci-app-frpc，无需额外添加；这里只需补充 luci-app-ssr-plus 的来源。
#       fw876/helloworld 提供 luci-app-ssr-plus 及底层依赖（xray-core / v2ray-core 等）。
#       追加到 feeds.conf.default 末尾；真正让 helloworld 版胜出的是 build.yml 里
#       `feeds install -a -f` 的 -f（强制后者覆盖前者），否则官方 luci 源同名包先到先得会胜出。

SRC_BRANCH="${SOURCE_BRANCH:-openwrt-23.05}"
# 分支隔离：仅「真正的老 18.06（openwrt-18.06，4.x 内核）」跳过 helloworld master 源；
# openwrt-18.06-k5.4 是「18.06 包基础 + 5.4 新内核」，兼容 helloworld / ngrokc / frpc，放行。
case "$SRC_BRANCH" in
  openwrt-18.06-k*) : ;;                         # 18.06 + 新内核(k5.4)：放行 helloworld
  openwrt-18.06) echo "==> 旧版 18.06(老内核 4.x)，跳过 helloworld master 源（不兼容）"; exit 0 ;;
esac

echo "==> 添加 luci-app-ssr-plus 源（fw876/helloworld）"
echo "src-git helloworld https://github.com/fw876/helloworld.git;master" >> feeds.conf.default
