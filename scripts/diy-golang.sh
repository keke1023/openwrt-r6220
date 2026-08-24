#!/bin/bash
# DIY-GOLANG: 在 ./scripts/feeds update -a 之后、feeds install -a 之前运行
# （当前位于 openwrt 源码根目录，此时 feeds/packages/ 已由 feeds update 拉取展开）
#
# 作用：升级 Golang 工具链，满足 xray-core 编译需求。
#
# 背景：18.06-k5.4 自带的 feeds/packages/lang/golang 版本过低（Go < 1.21），
#       helloworld 的 xray-core 各版本对 Go 都有自己的最低要求：
#       - 本仓库锁的 xray-core v1.8.24（go.mod 要求 go 1.21）：用 Go 1.22（sbwml 22.x）最稳，
#         既不缺（>=1.21）、又不会因 Go 过新（如 1.26）触发 sing 老依赖
#         `net.errNoSuchInterface` 链接错误（invalid reference to net.errNoSuchInterface）。
#       - 若日后切到 xray-core v25/v26（go.mod 要求 go 1.25+/1.26），再把此处换回 26.x。
#
# 方案（社区验证，见 openwrt-passwall/xray-core 讨论）：
#   整体替换 feeds/packages/lang/golang 为 sbwml/packages_lang_golang 的对应分支
#   （分支号 = Go 大版本）。该仓库的 golang-package.mk 机制与 OpenWrt 22.03+ 一致、
#   对 18.06-k5.4 可直接 include，且 host 构建从 dl.google.com 下载 Go 源码 bootstrap。
#
# 为何放 feeds update 之后：
#   feeds update -a 才会把 packages feed 展开到 feeds/packages/；在此之前该目录不存在。
#   若提前替换会被 feeds update 的 git 操作覆盖/冲突，故必须在 update 之后、install 之前。
#
# 适用范围：仅 openwrt-18.06-k5.4（23.05 自带 Go 够新无需升级；老 18.06 4.x 不编 xray-core）。

SRC_BRANCH="${SOURCE_BRANCH:-openwrt-23.05}"
case "$SRC_BRANCH" in
  openwrt-18.06-k*) : ;;                         # 18.06 + 新内核(k5.4)：需要升级 golang
  *) echo "==> 非 18.06-k5.4 分支（${SRC_BRANCH}），跳过 Golang 升级（自带版本足够）"; exit 0 ;;
esac

if [ ! -d "feeds/packages/lang" ]; then
  echo "!! 错误：feeds/packages/lang 不存在，请确认本脚本在 feeds update -a 之后运行"
  exit 1
fi

# xray-core v1.8.24 -> go 1.21 需求 -> 选用 Go 1.22 (sbwml 22.x)
GOLANG_BRANCH="22.x"
echo "==> 升级 Golang 工具链为 Go 1.22 (sbwml/packages_lang_golang ${GOLANG_BRANCH})"
echo "==> 当前自带 golang 版本："
grep -E "^PKG_VERSION|^GO_VERSION" feeds/packages/lang/golang/golang/Makefile 2>/dev/null | head -3 || echo "  (无法读取旧版本)"

rm -rf feeds/packages/lang/golang
git clone --depth 1 -b "$GOLANG_BRANCH" https://github.com/sbwml/packages_lang_golang.git feeds/packages/lang/golang
if [ ! -f "feeds/packages/lang/golang/golang/Makefile" ]; then
  echo "!! 错误：golang 包替换失败，feeds/packages/lang/golang/golang/Makefile 不存在"
  exit 1
fi

echo "==> Golang 工具链已升级，新版本："
grep -E "^GO_VERSION_MAJOR_MINOR|^GO_VERSION_PATCH" feeds/packages/lang/golang/golang/Makefile | tr '\n' ' '
echo
