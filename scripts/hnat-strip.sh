#!/bin/bash
# HNAT-STRIP: 在 make defconfig 之后运行（当前位于 openwrt 源码根目录，.config 已生成）
#
# 作用：把 defconfig 之后仍然存在的「默认全家桶 / 无线 / USB」压成 =n，
#       并导出剔除清单给 build.yml 的 kconfig 一致性校验用（/tmp/force-off.list）。
#
# 与 scripts/diy-strip.sh 的区别：那份是 18.06 线专用的，里面混着 ath10k、
# zramswap、k2p 闭源/开源无线切换等大量本线不需要的分支。本线只做一件事：
# 把一个「默认带无线和 USB 的 21.02 结构系统」压成纯有线代理网关。
#
# 两条硬规则（沿用 18.06 线踩坑结论）：
#   1) libiwinfo / libiwinfo-lua / libiwinfo-data **绝对不能** =n
#      —— luci 元包 LUCI_DEPENDS 写死 +libiwinfo-lua，置 n 会被 kconfig 翻回 y，
#         触发 out of sync，打包阶段按 .config 不产出 ipk，最终 opkg Error 255。
#         它们是纯用户态库，一个 kmod 都不拉，与「无无线」不冲突。
#   2) 只对「defconfig 后确实是 =y」的包动手
#      —— 有些包是 HIDDEN:=1，.config 里本来就不出现，硬写 =n 会制造
#         「写了 =n 却被求解成 y」的假报警，反而挡住构建。

TARGET_CONFIG="${TARGET_CONFIG:-}"
echo "==> HNAT-STRIP 开始（机型：${TARGET_CONFIG:-未注入}）"

# ---------------------------------------------------------------------------
# 剔除清单
# ---------------------------------------------------------------------------
FORCE_OFF_LIST="
kmod-mt76x2
kmod-mt76
kmod-mt7602e
kmod-mt7612e
kmod-mac80211
kmod-cfg80211
kmod-mt76-sdio
kmod-mt76-pci
wpad-basic
wpad-basic-mbedtls
wpad-basic-wolfssl
wpad-openssl
wpad-wolfssl
wpad-mbedtls
wpad
wireless-regdb
# hostapd 自身：wpad-* 一关，hostapd-common 仍会被 target 默认包或某处 select 拉回，
# 它一在，整个 package/network/services/hostapd 目录都要编译（run 42372404613 实测）。
hostapd
hostapd-common
hostapd-utils
wireless-tools
swconfig
prism54-firmware
p54-usb-firmware
p54-pci-firmware
p54-spi-firmware
mtkhqos_util
luci-app-eqos-mtk
luci-app-mwan3helper-chinaroute
ebtables
kmod-ebtables
kmod-ebtables-ipv4
kmod-ebtables-ipv6
kmod-usb-core
kmod-usb2
kmod-usb3
kmod-usb-ehci
kmod-usb-ohci
kmod-usb-uhci
kmod-usb-dwc2
kmod-usb-storage
kmod-usb-storage-extras
kmod-usb-storage-uas
kmod-usb-ledtrig-usbport
kmod-usb-hid
kmod-usb-net
kmod-usb-net-cdc-ether
kmod-usb-net-rtl8152
kmod-usb-serial
kmod-usb-printer
usbutils
usb-modeswitch
libusb-1.0
libusb-compat
block-mount
kmod-scsi-core
kmod-fs-ext4
kmod-fs-vfat
kmod-fs-ntfs
kmod-fs-exfat
kmod-fs-f2fs
e2fsprogs
fdisk
lsblk
luci-app-hd-idle
luci-app-diskman
luci-app-passwall
luci-app-rclone
luci-app-turboacc
luci-app-turboacc-mtk
luci-app-filetransfer
luci-lib-fs
kmod-ipt-offload
kmod-nf-flow
kmod-nf-nathelper-extra
ppp
ppp-mod-pppoe
odhcpd
"

# 无线的 shell 工具（iwinfo 只是命令行工具，无人依赖；libiwinfo* 不动）
FORCE_OFF_LIST="$FORCE_OFF_LIST
iwinfo
"

# ---------------------------------------------------------------------------
# 逐个压成 =n：只处理「当前明确为 =y」的项
# ---------------------------------------------------------------------------
: > /tmp/force-off.list
CHANGED=0
for p in $FORCE_OFF_LIST; do
  [ -n "$p" ] || continue
  if grep -q "^CONFIG_PACKAGE_${p}=y$" .config; then
    sed -i "s/^CONFIG_PACKAGE_${p}=y$/CONFIG_PACKAGE_${p}=n/" .config
    echo "$p" >> /tmp/force-off.list
    CHANGED=$((CHANGED + 1))
  fi
done
echo "==> 已把 $CHANGED 个包从 =y 压成 =n（清单见 /tmp/force-off.list）"

# ---------------------------------------------------------------------------
# 复核：无线 / USB 必须彻底消失
# 这里只看「.config 里还是 =y 的」，给出明确失败原因，不静默放过。
# ---------------------------------------------------------------------------
BAD=$(grep -E '^CONFIG_PACKAGE_(kmod-mt76[a-z0-9_-]*|kmod-mac80211|kmod-cfg80211|wpad[a-z0-9_.-]*|wireless-regdb)=(y|m)$' .config || true)
if [ -n "$BAD" ]; then
  echo "!! 失败：以下无线相关包仍被选中（多半是 DEVICE_PACKAGES 或 select 拉回）："
  echo "$BAD"
  echo "!! 排查：target/linux/ramips/image/mt7621.mk 的 Device/iptime_a3004ns-dual 里 DEVICE_PACKAGES 是否已清空（hnat-part2.sh [3]）"
  exit 1
fi
echo "OK：无线栈已清空"

BADU=$(grep -E '^CONFIG_PACKAGE_(kmod-usb[^=]*|usbutils|libusb[^=]*|block-mount)=(y|m)$' .config || true)
if [ -n "$BADU" ]; then
  echo "!! 失败：以下 USB/存储包仍被选中："
  echo "$BADU"
  exit 1
fi
echo "OK：USB 与存储链已清空"

# ---------------------------------------------------------------------------
# luci 硬依赖三件套必须在（这是 18.06 线 Error 255 的直接原因，这里提前拦）
# ---------------------------------------------------------------------------
for p in libiwinfo libiwinfo-lua libiwinfo-data; do
  if ! grep -qE "^CONFIG_PACKAGE_${p}=y$" .config; then
    echo "!! 失败：CONFIG_PACKAGE_${p} 不是 y —— luci 元包会装不上（opkg Error 255）"
    exit 1
  fi
done
echo "OK：libiwinfo 三件套齐备"

# ---------------------------------------------------------------------------
# shadow 密码提示：本固件默认 root 无密码（首次登录用 LuCI 设置或直接按回车）
# 与 18.06 线保持一致，不在这里改。
# ---------------------------------------------------------------------------
echo "==> HNAT-STRIP 完成"
