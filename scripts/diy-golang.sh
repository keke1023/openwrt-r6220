#!/bin/bash
# DIY-GOLANG: 在 ./scripts/feeds update -a 之后、feeds install -a 之前运行
# （当前位于 openwrt 源码根目录，此时 feeds/packages/ 已由 feeds update 拉取展开）
#
# 作用：升级 Golang 工具链，满足 xray-core 编译需求。
#
# 背景：各分支自带 feeds/packages/lang/golang 版本与 helloworld 的 xray-core 需求不匹配：
#   - openwrt-18.06-k5.4：按机型区分（见下方 case）——
#       · 小闪存机型(k2p 等 16MB，helloworld 仍 pin 到 xray v1.8.24)：自带 golang < 1.21 过低，
#         但 xray v1.8.24 的 sing 老依赖在 Go 1.26 上会触发 `net.errNoSuchInterface` 链接错误，
#         故升到 Go 1.22（sbwml 22.x）最稳（>=1.21 且不过新，避开老依赖链接错误）。
#       · 大闪存机型(dw33d 128MB，helloworld 用 master 最新 xray v26.5.9，go.mod 要求 go 1.26)：
#         必须升到 Go 1.26（sbwml 26.x）才能源码编译。
#   - openwrt-23.05 / master（helloworld 最新，xray-core v25/v26，go.mod 要求 go 1.25+/1.26）：
#       自带 golang（23.05 约 1.21/1.22）过低，编不过，必须升到 Go 1.26（sbwml 26.x 最新）。
#
# 方案（社区验证，见 openwrt-passwall/xray-core 讨论）：
#   整体替换 feeds/packages/lang/golang 为 sbwml/packages_lang_golang 的对应分支
#   （分支号 = Go 大版本）。该仓库的 golang-package.mk 机制与 OpenWrt 22.03+ 一致，
#   对 18.06-k5.4 / 23.05 均可直接 include，host 构建从 dl.google.com 下载 Go 源码 bootstrap。
#
# 为何放 feeds update 之后：
#   feeds update -a 才会把 packages feed 展开到 feeds/packages/；在此之前该目录不存在。
#   若提前替换会被 feeds update 的 git 操作覆盖/冲突，故必须在 update 之后、install 之前。

SRC_BRANCH="${SOURCE_BRANCH:-openwrt-23.05}"
# 当前编译机型（由 build.yml 经 env 传入，形如 dw33d.config）；用于按机型决定 Go 大版本：
#   dw33d(128MB) 追 master 最新 xray v26.5.9，需 Go 1.26；其余 18.06-k5.4 小闪存保持 Go 1.22
#   （避开 xray v1.8.24 老 sing 依赖在 Go 1.26 上的 net.errNoSuchInterface 链接错误）。
DEVICE_TARGET="${DEVICE_TARGET:-}"
DEVICE="${DEVICE_TARGET%.config}"        # 去掉 .config 后缀，得纯设备名

# 仅「真正的老 18.06（openwrt-18.06，4.x 内核）」不编 xray-core，跳过升级。
case "$SRC_BRANCH" in
  openwrt-18.06) echo "==> 旧版 18.06(老内核 4.x) 不编 xray-core，跳过 Golang 升级"; exit 0 ;;
esac

if [ ! -d "feeds/packages/lang" ]; then
  echo "!! 错误：feeds/packages/lang 不存在，请确认本脚本在 feeds update -a 之后运行"
  exit 1
fi

# 按「分支 + 机型」选 Go 大版本：
#   - 23.05 / master：Go 1.26（最新 xray v25/v26 的 go.mod 要求 1.25+/1.26）
#   - 18.06-k5.4 + dw33d(128MB)：Go 1.26（master 最新 xray v26.5.9 需 Go 1.26）
#   - 18.06-k5.4 + 其它小闪存机型(k2p 等)：Go 1.22（pin 的 xray v1.8.24 老 sing 依赖避开 1.26 链接错误）
case "$SRC_BRANCH" in
  openwrt-18.06-k*)
    if [ "$DEVICE" = "dw33d" ]; then
      GOLANG_BRANCH="26.x"   # dw33d 追 master 最新 xray v26.5.9，需 Go 1.26
    else
      GOLANG_BRANCH="22.x"   # 小闪存机型保持 Go 1.22（避开 xray v1.8.24 老 sing 链接错误）
    fi
    ;;
  *) GOLANG_BRANCH="26.x" ;;
esac

echo "==> 升级 Golang 工具链为 Go ${GOLANG_BRANCH%%.x} (sbwml/packages_lang_golang ${GOLANG_BRANCH})"
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
