#!/bin/bash
# DIY-P1: 在 ./scripts/feeds update/install 之前运行（当前位于 openwrt 源码根目录）
# 作用：添加第三方软件源。
# 说明：本配置基于 immortalwrt，其官方 feeds 已自带 luci-app-ngrokc、ngrokc、
#       luci-app-frpc，无需额外添加；这里只需补充 luci-app-ssr-plus 的来源。
#       fw876/helloworld 提供 luci-app-ssr-plus 及底层依赖（xray-core / v2ray-core 等）。
#       追加到 feeds.conf.default 末尾，使其同名包优先级高于官方源，确保 ssr-plus 用 helloworld 版本。

echo "==> 添加 luci-app-ssr-plus 源（fw876/helloworld）"
echo "src-git helloworld https://github.com/fw876/helloworld.git;master" >> feeds.conf.default
