#!/bin/bash
# HNAT-STRIP: 在 make defconfig 之后运行（当前位于 openwrt 源码根目录，.config 已生成）
#
# 作用：把 defconfig 之后仍然存在的「默认全家桶 / 无关组件」压成 =n，
#       并导出剔除清单给 build.yml 的 kconfig 一致性校验用（/tmp/force-off.list）。
#
# ============================================================================
# 两个机型的剔除集**不是超集关系**，必须分开写（这一点最容易出错）
# ============================================================================
#   a3004ns-dual : 纯有线。无线栈（mt76/mac80211/cfg80211/wpad/hostapd/
#                  wireless-tools/wireless-regdb）+ swconfig + ppp 全剔。
#   k2p          : 闭源无线 + swconfig。以下**一个都不能剔**：
#                    kmod-mac80211 / kmod-cfg80211  ← wpad 与 iwinfo 要用
#                    wpad-basic                     ← WPA 握手的前端
#                    wireless-tools                 ← mt_wifi 的 DEPENDS 就是它
#                    swconfig                       ← K2P 的 VLAN 划分靠它
#                    wireless-regdb                 ← 信道/功率规范
#                  剔了 wireless-tools 的后果很隐蔽：kconfig 会把它当依赖拉回来，
#                  然后一致性校验报「=n 却被翻成 y」，看上去像配置写错。
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
case "$TARGET_CONFIG" in
  k2p.config)
    MODEL_KIND="k2p"
    ;;
  a3004ns-dual.config|"")
    MODEL_KIND="a3004ns"
    ;;
  *)
    echo "!! 错误：hnat-strip.sh 不认识机型 '$TARGET_CONFIG'"
    echo "!!       已知：a3004ns-dual.config / k2p.config"
    echo "!!       新增机型必须显式加分支：默认走 a3004ns 的剔除集，会把闭源无线"
    echo "!!       （wpad / wireless-tools / mac80211）全剔掉，编出「有界面没信号」的固件"
    exit 1
    ;;
esac
echo "==> HNAT-STRIP 开始（机型：${TARGET_CONFIG:-未注入}，形态：${MODEL_KIND}）"

# ---------------------------------------------------------------------------
# 公共剔除清单：与交换形态、无线方案都无关的「本机用不上」
# ---------------------------------------------------------------------------
FORCE_OFF_COMMON="
# prism54 / p54：Intersil 老无线网卡固件，两台机器都用不到
prism54-firmware
p54-usb-firmware
p54-pci-firmware
p54-spi-firmware
# MTK QoS 的 **LuCI 界面**（注意不是 mtkhqos_util 本体）：
# 它的 LUCI_DEPENDS 是 +ebtables +kmod-ebtables-ipv4 +kmod-ebtables-ipv6，
# 是这三件套的唯一来源，剔掉界面就能连带甩掉三个 kmod
luci-app-eqos-mtk
luci-app-mwan3helper-chinaroute
ebtables
kmod-ebtables
kmod-ebtables-ipv4
kmod-ebtables-ipv6
# USB 链：两台机器都没有可用的 USB 口
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
# 存储链（没有 USB，也没有 SATA）
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
# 与 HNAT 抢同一条转发路径的软件 offload（fw3 的 flowtable 硬件档）
kmod-ipt-offload
kmod-nf-flow
kmod-nf-nathelper-extra
# 无关界面
luci-app-passwall
luci-app-rclone
luci-app-turboacc
luci-app-turboacc-mtk
luci-app-filetransfer
luci-lib-fs
"

# ---------------------------------------------------------------------------
# 机型专属部分
# ---------------------------------------------------------------------------
if [ "$MODEL_KIND" = "a3004ns" ]; then
FORCE_OFF_LIST="$FORCE_OFF_COMMON
# ---- a3004ns 专属：整条无线栈（本机纯有线）----
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
# swconfig 是 swconfig 机型的配置工具；本机是 DSA，VLAN 由 bridge/dsa 管
swconfig
# 无线的 shell 工具（libiwinfo* 不动，见文件头规则 1）
iwinfo
# 拨号：本机是二级路由，WAN 走 DHCP
ppp
ppp-mod-pppoe
odhcpd
"
else
FORCE_OFF_LIST="$FORCE_OFF_COMMON
# ---- k2p 专属：只剔「开源 mt76」与「多余 wpad 变体」，闭源栈一律保留 ----
# 开源 mt76 与闭源 mt_wifi 抢同一张 PCI 卡（dts 的 pcie0 compatible=\"mediatek,mt76\"），
# 开源驱动一旦在，闭源就拿不到设备 → 界面在、没信号。
kmod-mt7615e
kmod-mt7615-firmware
kmod-mt76
kmod-mt76-core
kmod-mt76-connac
kmod-mt76x2
kmod-mt7603
kmod-mt7602e
kmod-mt7612e
# wpad 只能有一个变体，否则 PROVIDES 冲突（wpad-basic 是配置里钉的那个）
wpad-basic-wolfssl
wpad-basic-mbedtls
wpad-openssl
wpad-wolfssl
wpad-mbedtls
wpad-mini
wpad
# 独立 hostapd 包与 wpad-basic 功能重叠，会被 PROVIDES 判成冲突
hostapd
hostapd-utils
"
fi

# ---------------------------------------------------------------------------
# 逐个压成 =n：只处理「当前明确为 =y」的项
#
# 注意：清单里混着中文注释，而 `for p in $LIST` 是按空白拆词的 ——
# 直接遍历会把注释里的词（例如「注意不是 mtkhqos_util 本体」里的 mtkhqos_util）
# 当成包名处理，把我们要保留的包剔掉。所以先按行剥掉 # 之后的内容再遍历。
# ---------------------------------------------------------------------------
PKG_LIST=$(printf '%s\n' "$FORCE_OFF_LIST" | sed -e 's/#.*//' -e 's/[[:space:]]//g' | grep -v '^$')
: > /tmp/force-off.list
CHANGED=0
for p in $PKG_LIST; do
  [ -n "$p" ] || continue
  if grep -q "^CONFIG_PACKAGE_${p}=y$" .config; then
    sed -i "s/^CONFIG_PACKAGE_${p}=y$/CONFIG_PACKAGE_${p}=n/" .config
    echo "$p" >> /tmp/force-off.list
    CHANGED=$((CHANGED + 1))
  fi
done
echo "==> 已把 $CHANGED 个包从 =y 压成 =n（清单见 /tmp/force-off.list）"

# ---------------------------------------------------------------------------
# 复核 A：机型相关的「必须没有 / 必须都在」
# ---------------------------------------------------------------------------
if [ "$MODEL_KIND" = "a3004ns" ]; then
  BAD=$(grep -E '^CONFIG_PACKAGE_(kmod-mt76[a-z0-9_-]*|kmod-mac80211|kmod-cfg80211|wpad[a-z0-9_.-]*|wireless-regdb)=(y|m)$' .config || true)
  if [ -n "$BAD" ]; then
    echo "!! 失败：以下无线相关包仍被选中（多半是 DEVICE_PACKAGES 或 select 拉回）："
    echo "$BAD"
    echo "!! 排查：mt7621.mk 的 Device/iptime_a3004ns-dual 里 DEVICE_PACKAGES 是否已清空（hnat-part2.sh [3]）"
    exit 1
  fi
  echo "OK：无线栈已清空"
else
  # k2p 正向：闭源无线三层 + 承载它们的底座必须齐备
  MISS=""
  for p in kmod-mt7615d mt_wifi wpad-basic kmod-mac80211 kmod-cfg80211 \
           wireless-tools swconfig; do
    grep -qE "^CONFIG_PACKAGE_${p}=y$" .config || MISS="$MISS $p"
  done
  if [ -n "$MISS" ]; then
    echo "!! 失败：以下闭源无线/交换底座包不在 .config 里："
    for p in $MISS; do echo "   CONFIG_PACKAGE_${p}"; done
    echo "!! 后果：mt_wifi.ko 缺失（有界面没信号）、或 VLAN 配不了、或 WPA 握不上手"
    echo "!! 排查：k2p.config 里是否误写 =n；mt7621.mk 的 DEVICE_PACKAGES 是否被改写"
    exit 1
  fi
  # k2p 反向：开源 mt76 不能出现。
  # 这里必须用「整名 + = 锚定」，不能写成 kmod-mt76[a-z0-9]*——那个前缀会把
  # 合法的 kmod-mt7615d（闭源）一起匹配掉，正是本轮写错后被自己拦下的那种误判。
  BADM=$(grep -E '^CONFIG_PACKAGE_(kmod-mt7615e|kmod-mt7615-firmware|kmod-mt76|kmod-mt76-core|kmod-mt76-connac|kmod-mt76x2|kmod-mt7603|kmod-mt7602e|kmod-mt7612e)=(y|m)$' .config || true)
  if [ -n "$BADM" ]; then
    echo "!! 失败：开源 mt76 驱动仍被选中，会与闭源 mt_wifi 抢同一张 PCI 卡："
    echo "$BADM"
    exit 1
  fi
  # k2p 反向：wpad 只能有一个变体
  BADW=$(grep -E '^CONFIG_PACKAGE_(wpad-basic-wolfssl|wpad-basic-mbedtls|wpad-openssl|wpad-wolfssl|wpad-mbedtls|wpad-mini|wpad)=(y|m)$' .config || true)
  if [ -n "$BADW" ]; then
    echo "!! 失败：除 wpad-basic 之外还有别的 wpad 变体被选中（PROVIDES 冲突）："
    echo "$BADW"
    echo "!! 排查：target.mk 的 DEFAULT_PACKAGES += wpad-basic-wolfssl 未被压住"
    exit 1
  fi
  echo "OK：K2P 闭源无线栈齐备（kmod-mt7615d + mt_wifi + wpad-basic + wireless-tools），且无开源 mt76 / 无多余 wpad"
fi

# ---------------------------------------------------------------------------
# 复核 B：USB / 存储（两台机器都要没有）
# ---------------------------------------------------------------------------
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
