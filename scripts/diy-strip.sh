#!/bin/bash
# DIY-STRIP: 在 make defconfig 之后运行（当前位于 openwrt 源码根目录，.config 已生成）
#
# 作用：强制剔除「默认全家桶」LuCI 应用，确保 16MB SPI 不被撑爆。
#
# 背景：immortalwrt 的 default-settings-chn / DEFAULT_PACKAGES.tweak 用 default y 甚至
#       select 把一批 LuCI 应用（diskman / passwall / rclone / turboacc）默认拽入。
#       在 config-*.config 里写 =n 仍可能被 select 覆盖（实测 turboacc 的 TURBOACC_INCLUDE_*
#       子项 defconfig 后仍 =y），故必须在 defconfig 之后用 sed 强制 =n。
#
# ⚠️ 重要：本脚本【不】动 openssl / libustream-openssl / wpad-basic！
#   原因是 openssl 是被核心包硬依赖的，删了会导致 opkg install 阶段崩溃：
#     - ngrokc        → 依赖 libopenssl1.1（用户明确要求，不可删）
#     - default-settings(-chn) → 依赖 libopenssl1.1
#     - libcurl4(→curl)        → 依赖 libopenssl1.1
#     - luci-lib-nixio         → 依赖 libopenssl1.1
#     - luci-app-ssr-plus      → 依赖 libustream-openssl20201210
#   所以 openssl 必须保留（这是 immortalwrt 18.06-k5.4 的自然状态）。要省空间，
#   真正的杠杆是 helloworld 整库回退到 xray v1.8.24（已在 diy-part1 完成，省 ~10MB）
#   以及下面的独立全家桶剔除，必要时再砍 ath10k 5G 固件（~1.5MB）。
#
# ⚠️ 关键陷阱（实测踩过）：
#   - `make defconfig` 会把 default y 的包翻回 =y，会把阶段1的 =n 废掉。
#   - 因此采用「两阶段 sed」：阶段1 sed =n → 阶段2 defconfig 补全新符号 →
#     阶段3 再次 sed =n（此时 default y 的能被显式 =n 覆盖）→ 阶段4 不跑 defconfig，
#     直接交棒给后续 make（make 会自动 oldconfig 补全，但不会把已显式 =n 的翻回）。
#
# ⚠️ dns2socks / dns2tcp / microsocks / chinadns-ng 是 luci-app-ssr-plus 的硬依赖
#   （Makefile DEPENDS/select），不可强制 =n，否则 luci-app-ssr-plus/compile 报
#   "No rule to make target .../dns2socks/compile"。它们随 ssr-plus 默认选中，保留。

echo "==> [阶段1] 强制 =n（defconfig 前初次标记）"
FORCE_OFF="\
luci-app-diskman \
luci-app-diskman_INCLUDE_btrfs_progs \
luci-app-diskman_INCLUDE_lsblk \
luci-app-passwall \
luci-app-passwall_INCLUDE_ShadowsocksR_Libev_Client \
luci-app-passwall_INCLUDE_Shadowsocks_Libev_Client \
luci-app-passwall_INCLUDE_Simple_Obfs \
luci-app-passwall_INCLUDE_Trojan_Plus \
luci-app-rclone \
luci-app-rclone_INCLUDE_rclone-ng \
luci-app-rclone_INCLUDE_rclone-webui \
luci-app-turboacc \
TURBOACC_INCLUDE_BBR_CCA \
TURBOACC_INCLUDE_OFFLOADING \
TURBOACC_INCLUDE_SHORTCUT_FE \
TURBOACC_INCLUDE_SHORTCUT_FE_DRV \
"

# ---------------------------------------------------------------------------
# 按机型追加剔除项：16MB 纯有线机型（a3004ns-dual）关掉整个无线子系统
# ---------------------------------------------------------------------------
# 为什么必须在 defconfig 之后强制 =n：
#   ramips/mt7621 的 target.mk DEFAULT_PACKAGES 里带 kmod-mt76x2 + wpad-basic，
#   而 kmod-mt76x2 会经 DEPENDS/select 把 kmod-mt76-core → kmod-mac80211 → kmod-cfg80211
#   整条链拽进来（合计约 1.2MiB）。在 config-*.config 里写 =n 常被 select 覆盖，
#   只有 defconfig 后逐个 sed 才压得住。
#   ⚠️ 仅对 a3004ns 生效：dw33d(ath79) 等机型要 wifi，不能全局关 wpad/wireless-regdb。
#
#   ❗ libiwinfo / libiwinfo-lua / libiwinfo-data 绝对不能进这份剔除清单。
#      它们看着像"无线"，其实是纯用户态库（libiwinfo-lua → libiwinfo → libiwinfo-data，
#      DEPENDS 只有 libnl-tiny/libuci/libubus/liblua，一个 kmod 都不拉），
#      而 luci 元包（collections/luci/Makefile:13-16）的 LUCI_DEPENDS 写死了 +libiwinfo-lua。
#      一旦置 =n，kconfig 求解会把它翻回 =y（与 .config 冲突 → out of sync），
#      打包阶段却按 .config 不产出该 ipk，最终 package/install 阶段 opkg 报
#      "cannot find dependency libiwinfo-lua for luci" → Error 255（run 111661978562 实测）。
#      只保留 iwinfo 命令行工具关闭即可（无人依赖它）。
TARGET_CONFIG="${TARGET_CONFIG:-}"

# ---------------------------------------------------------------------------
# 16MB 机型共用瘦身（a3004ns / k2p 都适用）
# ---------------------------------------------------------------------------
# 只收「有硬证据表明没有任何包依赖它」的项：
#   kmod-nf-nathelper-extra —— FTP/SIP/IRC/H.323 的 conntrack ALG 助手（≈53KB 安装）。
#     已核 18.06 索引：没有任何包的 Depends 引用它（firewall 的 DEPENDS 里也没有），
#     它是 ramips 默认包里的「顺手带上」项。家用路由不需要 ALG，关掉纯赚。
#   ❗ 注意：ubi-utils **不能**动 —— 它被 base-files 和 fstools 硬依赖
#     （p186.txt: base-files Depends ... ubi-utils；fstools Depends ... ubi-utils），
#     强制 =n 会被 kconfig 拉回 =y，直接触发校验0 失败。想省这 70KB 得改 fstools/base-files
#     的 Makefile，风险远大于收益。
if echo "$TARGET_CONFIG" | grep -qiE 'a3004ns|k2p|wr1200js|zte_e8821'; then
  echo "==> 16MB 机型（$TARGET_CONFIG）：追加共用瘦身项（conntrack ALG 助手）"
  FORCE_OFF="$FORCE_OFF \
kmod-nf-nathelper-extra \
"
fi

if echo "$TARGET_CONFIG" | grep -qiE 'a3004ns'; then
  echo "==> 检测到 16MB 纯有线机型（$TARGET_CONFIG），追加剔除整个无线子系统"
  FORCE_OFF="$FORCE_OFF \
kmod-mt76x2 \
kmod-mt76-core \
kmod-mt76 \
kmod-mac80211 \
kmod-cfg80211 \
kmod-mt7602e \
kmod-mt7612e \
wpad-basic \
wpad-basic-mbedtls \
wpad-basic-wolfssl \
wpad-openssl \
wpad-wolfssl \
wpad \
wireless-regdb \
"
  # -------------------------------------------------------------------------
  # 整条 USB 链剔除（本机纯有线，明确不用 U 盘）
  # -------------------------------------------------------------------------
  # 为什么还要在这里压一遍：
  #   1) include/target.mk 的 DEFAULT_PACKAGES.tweak 里写死了 block-mount（默认 y），
  #      config-*.config 里的 =n 在 defconfig 阶段可能被 default y 翻回；
  #   2) kmod-usb3 / kmod-usb-ledtrig-usbport 原本在 DEVICE_PACKAGES 里，已由
  #      diy-part2.sh 在 defconfig 之前从 mt7621.mk 剔掉，但保险起见再压一次；
  #   3) devinfo/feeds 里若有包 select 了 kmod-usb-core，也只有在这里能压住。
  # 关掉 kmod-usb-core ⇒ 内核 CONFIG_USB 不被置位 ⇒ USB 子系统整体不编进固件
  #（mt7621 的 config-5.4 只有 CONFIG_USB_SUPPORT=y 这个菜单总开关，不产生代码）。
  echo "==> 检测到 16MB 纯有线机型（$TARGET_CONFIG），追加剔除整条 USB 链"
  FORCE_OFF="$FORCE_OFF \
kmod-usb-core \
kmod-usb2 \
kmod-usb3 \
kmod-usb-ehci \
kmod-usb-ohci \
kmod-usb-uhci \
kmod-usb-dwc2 \
kmod-usb-storage \
kmod-usb-storage-extras \
kmod-usb-storage-uas \
kmod-usb-ledtrig-usbport \
kmod-usb-hid \
kmod-usb-net \
kmod-usb-net-cdc-ether \
kmod-usb-net-rtl8152 \
kmod-usb-serial \
kmod-usb-serial-ftdi \
kmod-usb-printer \
usbutils \
usb-modeswitch \
libusb-1.0 \
libusb-compat \
block-mount \
kmod-scsi-core \
kmod-fs-ext4 \
kmod-fs-vfat \
kmod-fs-ntfs \
kmod-fs-exfat \
kmod-fs-f2fs \
e2fsprogs \
fdisk \
lsblk \
luci-app-hd-idle \
"
  # -------------------------------------------------------------------------
  # Luci 冗余应用（都来自 include/target.mk 的 DEFAULT_PACKAGES.tweak，默认 y）
  # -------------------------------------------------------------------------
  #   luci-app-filetransfer + luci-lib-fs：文件传输页面，filetransfer 的
  #     LUCI_DEPENDS 就是 +luci-lib-fs，两者是唯一依赖关系，可一起关。
  #   luci-app-cpufreq：LUCI_DEPENDS:=@(arm||aarch64)，MIPS 上本就选不中，
  #     这里压一遍只是防上游把依赖放宽。
  echo "==> 检测到 16MB 纯有线机型（$TARGET_CONFIG），追加剔除 Luci 冗余应用"
  FORCE_OFF="$FORCE_OFF \
luci-app-filetransfer \
luci-lib-fs \
luci-app-cpufreq \
"
  # 通配兜底：静态清单总会漏（kmod-usb-net-* / kmod-usb-serial-* 有几十个变体，
  # 且随内核版本增删），只有正则才能保证「一条 usb 都不剩」。
  usb_sweep() {
    [ -f .config ] || return 0
    sed -i -E 's/^CONFIG_PACKAGE_(kmod-usb[^=]*)=[ym]$/CONFIG_PACKAGE_\1=n/' .config
    sed -i -E 's/^CONFIG_PACKAGE_(usbutils|usb-modeswitch|libusb[^=]*)=[ym]$/CONFIG_PACKAGE_\1=n/' .config
  }
  echo "==> [阶段1.5] USB 通配清扫（kmod-usb* / usbutils / libusb*）"
  usb_sweep
fi

# ---------------------------------------------------------------------------
# 反向清单：必须保持 =y 的包
#   libiwinfo*：luci 元包硬依赖 libiwinfo-lua，且三者均为纯用户态库（不拉 kmod）。
#   这里显式拉回 =y，与 kconfig 的依赖求解结果保持一致 —— .config 与 make 视图
#   一旦分歧，就会在 package/install 阶段炸 opkg（见文件头部说明）。
# ---------------------------------------------------------------------------
FORCE_ON="libiwinfo libiwinfo-lua libiwinfo-data"

# ---------------------------------------------------------------------------
# K2P：无线走闭源 mt7615d（mt_wifi）—— 与开源方案相反，这里是「必须保留」
# ---------------------------------------------------------------------------
# 2026-11-04 起换回闭源驱动（开源 mt76 对 MT7615D DBDC 热重启有 bug，
# radio1 phy 消失 / HOSTAPD_START_FAILED，实机复现无法使用）。
# 为什么要在这里兜底：
#   1) 闭源包来自上游 DEVICE_PACKAGES（kmod-mt7615d luci-app-mtwifi），
#      只是「默认 y」的身份，config 里一旦写错成 =n 就会被压掉，
#      而少了驱动的固件是「能开机、没有 wifi」的静默失败，最难排查。
#   2) 开源 mt7615e 必须强制 =n：否则会与闭源 mt_wifi 抢同一张 PCI 卡。
#   3) wpad 显式选 wpad-basic（比 wpad-openssl 省约 100KB），
#      但 mt7621 的 target.mk DEFAULT_PACKAGES 里带的是 wpad-openssl，
#      两者 PROVIDES 同一个 wpad，必须确保只有 wpad-basic 是 y。
#   注：mt_wifi 不进 cfg80211/mac80211，mac80211/wpad-basic 纯为 LuCI 状态页与
#   iwinfo 保留（首次求稳，约 1MB；验证热重启修复后再评估砍不砍）。
if echo "$TARGET_CONFIG" | grep -qiE 'k2p'; then
  echo "==> K2P：闭源 mt_wifi 强制 =y，开源 mt7615e 强制 =n"
  FORCE_ON="$FORCE_ON \
kmod-mt7615d \
luci-app-mtwifi \
kmod-mac80211 \
kmod-cfg80211 \
wpad-basic \
wireless-regdb \
hostapd-common \
"
  FORCE_OFF="$FORCE_OFF \
kmod-mt7615e \
kmod-mt7615-firmware \
kmod-mt7603e \
kmod-mt7612e \
wpad-openssl \
wpad-wolfssl \
wpad \
wpad-mini \
wpad-basic-openssl \
wpad-basic-wolfssl \
"
fi

# ---------------------------------------------------------------------------
# WR1200JS：开源 mt76 双芯片（MT7603E 2.4G + MT7612E 5G）
# ---------------------------------------------------------------------------
# 与 K2P 的区别：
#   K2P 是 MT7615D 单芯片（mt7615e + 独立 firmware 包），上游 DEVICE_PACKAGES 本来是
#   闭源 mt7615d，被 diy-part2 [18] 段换成开源；WR1200JS 上游就是开源的
#   kmod-mt7603 + kmod-mt76x2，**不需要换驱动**，只需保证它们不被剃掉。
#   ❗ 千万别把 K2P 段的 kmod-mt7603e / kmod-mt7612e 排除项抄过来 —— 那两个是
#     「不存在包名」的防御项（真实包名是 kmod-mt7603 / kmod-mt76x2，驱动文件名才是
#     mt7603e.ko / mt76x2e.ko），照抄会误伤本机唯一的两块无线芯片。
# 必须兜底 =y：
#   kmod-mt7603   MT7603E 2.4G（DEPENDS +kmod-mt76-core）
#   kmod-mt76x2   MT7612E 5G（DEPENDS +kmod-mt76x2-common，后者带 mt7662.bin 固件）
#   加上 mac80211 / cfg80211 / wpad-basic / wireless-regdb / hostapd-common
# 必须 =n：
#   mt7615 全家（本机没有该芯片）、闭源 mt7615d / luci-app-mtwifi、
#   target.mk 默认的 wpad-openssl（与 wpad-basic 撞同一个 PROVIDES 名为 wpad）
# USB：本机有一个 USB3.0 口，但本配置已砍整条 USB 链（没有 opkg，装不了存储驱动，
#   留着也只是个不通的口）。DEVICE_PACKAGES 已由 diy-part2 [6/7/8] 段剔掉，
#   这里再压一遍，防止 DEFAULT_PACKAGES.tweak 的 block-mount 之类翻回来。
#   DTS 里 led 节点的 trigger-sources = <&xhci_ehci_port1>, <&ehci_port2> 不受影响
#   —— 那是静态 phandle 引用，DTC 只校验节点存在，不要求对应驱动编入。
if echo "$TARGET_CONFIG" | grep -qiE 'wr1200js'; then
  echo "==> WR1200JS：开源无线栈（mt7603 + mt76x2）强制 =y，mt7615 全家 + USB 链强制 =n"
  FORCE_ON="$FORCE_ON \
kmod-mt7603 \
kmod-mt76x2 \
kmod-mac80211 \
kmod-cfg80211 \
wpad-basic \
wireless-regdb \
hostapd-common \
"
  FORCE_OFF="$FORCE_OFF \
kmod-mt7615e \
kmod-mt7615-firmware \
kmod-mt7615d \
luci-app-mtwifi \
wpad-openssl \
wpad-wolfssl \
wpad \
wpad-mini \
wpad-basic-openssl \
wpad-basic-wolfssl \
kmod-usb-core \
kmod-usb2 \
kmod-usb3 \
kmod-usb-ehci \
kmod-usb-ohci \
kmod-usb-dwc2 \
kmod-usb-storage \
kmod-usb-storage-extras \
kmod-usb-storage-uas \
kmod-usb-ledtrig-usbport \
kmod-usb-hid \
kmod-usb-net \
kmod-usb-serial \
usbutils \
usb-modeswitch \
libusb-1.0 \
block-mount \
"
fi

# ---------------------------------------------------------------------------
# ZTE E8821：ath79/QCA9563 + ath10k-ct(smallbuffers) + QCA9882 5G
# ---------------------------------------------------------------------------
# 与 ramips 那几个机型的区别：
#   ① 无线栈是 **ath10k-ct**（PCIe 5G）+ **ath9k**（SoC 内置 2.4G），不是 mt76/mt_wifi，
#      所以绝不能把 a3004ns 段那串 kmod-mt76/... 抄过来（会误伤 ndo 无关但同样不存在的符号，
#      更重要的是别把 kmod-mac80211 / kmod-cfg80211 关掉 —— ath10k 和 ath9k 都要它）。
#   ② wpad：ath79 generic 的 DEFAULT_PACKAGES 是 **wpad-basic-openssl**（不是 wpad-openssl），
#      所以这里保 openssl 版、把其余变体压 =n。若误保 wpad-openssl + wpad-basic-openssl 两个，
#      打包期会因同一个 PROVIDES（wpad）撞车。
#   ③ 5G 驱动走 smallbuffers 变体（同一份源码的第二 VARIANT）。两个变体 PROVIDES 都是
#      kmod-ath10k，**必须一开一关**，否则装的是同一批 .ko，check_data_file_clashes。
#      想换回 regular：把 FORCE_ON 里的 -smallbuffers 换成 kmod-ath10k-ct，两处对调。
#   ④ 5G 固件必须是 qca988x-ct（9880/9882）。qca9888-ct 是 9886/9888 的，装错 5G 起不来。
#   ⑤ uboot-envtools：本机刷 breed，没有可用 U-Boot 环境区，DEVICE_PACKAGES 里已 -掉，
#      这里再压一遍防 DEFAULT_PACKAGES（ath79/Makefile 里有它）翻回来，省 ~45KB。
if echo "$TARGET_CONFIG" | grep -qiE 'zte_e8821'; then
  echo "==> E8821：ath10k-ct(smallbuffers) + qca988x-ct 强制 =y，其余无线/固件变体强制 =n"
  FORCE_ON="$FORCE_ON \
kmod-ath10k-ct-smallbuffers \
ath10k-firmware-qca988x-ct \
kmod-ath9k \
kmod-mac80211 \
kmod-cfg80211 \
wpad-basic-openssl \
wireless-regdb \
hostapd-common \
swconfig \
kmod-gpio-button-hotplug \
kmod-leds-gpio \
kmod-zram \
"
  FORCE_OFF="$FORCE_OFF \
kmod-ath10k-ct \
kmod-ath10k \
ath10k-firmware-qca9888-ct \
ath10k-firmware-qca9888-ct-full-htt \
ath10k-firmware-qca988x \
ath10k-firmware-qca988x-ct-full-htt \
ath10k-firmware-qca9887-ct \
wpad-openssl \
wpad-wolfssl \
wpad \
wpad-mini \
wpad-basic \
wpad-basic-wolfssl \
uboot-envtools \
zram-swap \
kmod-usb-core \
kmod-usb2 \
kmod-usb3 \
kmod-usb-ehci \
kmod-usb-ohci \
kmod-usb-storage \
usbutils \
block-mount \
"
fi

# 把最终剔除清单导出，供 CI 的「配置一致性校验」逐步核对
#（该步骤据此判断：被我们强制 =n 的符号，是否被 kconfig 求解又翻回 y/m）
FORCE_OFF_LIST="${FORCE_OFF_LIST:-/tmp/force-off.list}"
printf '%s\n' $FORCE_OFF | sed '/^$/d' | sort -u > "$FORCE_OFF_LIST"
echo "==> 剔除清单已导出：$FORCE_OFF_LIST（$(grep -c . "$FORCE_OFF_LIST") 项）"

for p in $FORCE_OFF; do
  sed -i "s/^CONFIG_PACKAGE_${p}=[ym]/CONFIG_PACKAGE_${p}=n/" .config
  if ! grep -qE "^CONFIG_PACKAGE_${p}=" .config && ! grep -q "^# CONFIG_PACKAGE_${p} is not set" .config; then
    echo "CONFIG_PACKAGE_${p}=n" >> .config
  fi
done

echo "==> [阶段2] make defconfig（补全新符号，会翻回部分 default y）"
make defconfig

echo "==> [阶段3] defconfig 后再次强制 =n（此时 default y 可被覆盖）"
for p in $FORCE_OFF; do
  sed -i "s/^CONFIG_PACKAGE_${p}=[ym]/CONFIG_PACKAGE_${p}=n/" .config
  if ! grep -qE "^CONFIG_PACKAGE_${p}=" .config && ! grep -q "^# CONFIG_PACKAGE_${p} is not set" .config; then
    echo "CONFIG_PACKAGE_${p}=n" >> .config
  fi
done
# USB 通配再扫一次：defconfig 会把 default y 的 block-mount 以及被 select 的 kmod-usb-* 翻回来
if echo "$TARGET_CONFIG" | grep -qiE 'a3004ns'; then
  usb_sweep
fi

# 反向强制 =y（见 FORCE_ON 定义处说明）
for p in $FORCE_ON; do
  sed -i "s/^CONFIG_PACKAGE_${p}=.*/CONFIG_PACKAGE_${p}=y/" .config
  grep -q "^CONFIG_PACKAGE_${p}=" .config || echo "CONFIG_PACKAGE_${p}=y" >> .config
done

# 硬件 offload 反向强制 =y：本机自用明确启用（config 里已 =y，这里兜底防被压回 =n）
#   kmod-ipt-offload → xt_FLOWOFFLOAD（含 --hw）
#   kmod-nf-flow     → 置位 CONFIG_NF_FLOW_TABLE + CONFIG_NF_FLOW_TABLE_HW，
#                      硬件卸载路径缺此符号会退化，故两者必须同时为 y
if echo "$TARGET_CONFIG" | grep -qiE 'a3004ns|k2p|wr1200js'; then
  for p in kmod-ipt-offload kmod-nf-flow; do
    sed -i "s/^CONFIG_PACKAGE_${p}=.*/CONFIG_PACKAGE_${p}=y/" .config
    grep -q "^CONFIG_PACKAGE_${p}=" .config || echo "CONFIG_PACKAGE_${p}=y" >> .config
  done
fi

echo "==> [阶段4] 不重跑 defconfig，直接复核关键包状态："
echo "--- 期望全为 =n（全家桶/turboacc 已剔除）---"
grep -E 'luci-app-diskman|luci-app-passwall|luci-app-rclone|luci-app-turboacc|TURBOACC_INCLUDE_' .config
echo "--- 确认 openssl 仍在（ngrokc/default-settings/libcurl/ssr-plus 硬依赖，必须保留）---"
grep -E '^CONFIG_PACKAGE_libopenssl=|^CONFIG_PACKAGE_libustream-openssl=|^CONFIG_PACKAGE_wpad-basic' .config

# ---------------------------------------------------------------------------
# 16MB 机型专项复核：无线必须全灭，xray/ssr-plus 必须在
# ---------------------------------------------------------------------------
if echo "$TARGET_CONFIG" | grep -qiE 'a3004ns'; then
  echo "--- [16MB 机型] 无线子系统复核（出现 =y/=m 即会超预算）---"
  #   libiwinfo* 是纯用户态库且被 luci 硬依赖，不算无线驱动，必须排除在检查之外
  BAD=$(grep -E '^CONFIG_PACKAGE_(kmod-mt76|kmod-mac80211|kmod-cfg80211|kmod-mt7602e|kmod-mt7612e|wpad|wireless-regdb)[^=]*=[ym]|^CONFIG_PACKAGE_iwinfo=[ym]' .config || true)
  if [ -n "$BAD" ]; then
    echo "$BAD"
    echo "!! 警告：仍有无线包被选中，实际体积会超 16MB 预算"
  else
    echo "OK：无线相关包全部未选中"
  fi
  echo "--- [16MB 机型] libiwinfo 三件套复核（必须 =y：luci 元包硬依赖 libiwinfo-lua）---"
  if grep -qE '^CONFIG_PACKAGE_libiwinfo-lua=y' .config; then
    grep -E '^CONFIG_PACKAGE_(libiwinfo|libiwinfo-lua|libiwinfo-data)=' .config
  else
    echo "!! 错误：libiwinfo-lua 未置 y，package/install 阶段 opkg 会报 cannot find dependency libiwinfo-lua for luci"
  fi
  echo "--- [16MB 机型] 代理链复核（应均为 =y）---"
  grep -E '^CONFIG_PACKAGE_(xray-core|luci-app-ssr-plus|chinadns-ng|iptables-mod-socket|dnsmasq-full)=' .config

  echo "--- [16MB 机型] USB 链复核（应全部未选中）---"
  BADUSB=$(grep -E '^CONFIG_PACKAGE_(kmod-usb[^=]*|usbutils|usb-modeswitch|libusb[^=]*|block-mount|kmod-scsi-core|kmod-fs-(ext4|vfat|ntfs|exfat|f2fs)|e2fsprogs)=[ym]' .config || true)
  if [ -n "$BADUSB" ]; then
    echo "$BADUSB"
    echo "!! 警告：仍有 USB/存储包被选中（多为上游 select 强制），体积会比预期略大"
  else
    echo "OK：USB 及存储相关包全部未选中（内核 CONFIG_USB 不会置位）"
  fi
  echo "--- [16MB 机型] Luci 冗余应用复核（应均为 =n）---"
  grep -E '^CONFIG_PACKAGE_(luci-app-filetransfer|luci-lib-fs|luci-app-cpufreq)=' .config || echo "（未出现在 .config，等效于未选中）"
  echo "--- [16MB 机型] 硬件 offload 复核（应均为 =y，缺一即不会真正走 PPE）---"
  grep -E '^CONFIG_PACKAGE_(kmod-ipt-offload|kmod-nf-flow)=' .config
  echo "--- [16MB 机型] 内核 USB 开关确认 ---"
  if [ -e build_dir/target-*/linux-*/linux-*/.config ]; then
    grep -E '^CONFIG_USB=|^CONFIG_USB_SUPPORT=|^CONFIG_USB_XHCI' build_dir/target-*/linux-*/linux-*/.config || true
  else
    echo "（内核尚未 configure，编译结束后可复审 build_dir 里的 .config：应无 CONFIG_USB=y/m）"
  fi
fi

# ---------------------------------------------------------------------------
# K2P 专项复核：闭源 mt_wifi 必须在、开源 mt7615e 必须不在
# ---------------------------------------------------------------------------
# 这里只「警告不失败」：真正致命的一致性问题（被 select 拉回）由 CI 的
# 「配置一致性校验」负责 exit 1；本段的价值是把「能开机但没 wifi」这种
# 静默失败在编译前就喊出来。
if echo "$TARGET_CONFIG" | grep -qiE 'k2p'; then
  echo "--- [K2P] 闭源无线栈复核（必须 =y）---"
  MISSING=""
  for p in kmod-mt7615d luci-app-mtwifi kmod-mac80211 kmod-cfg80211 wpad-basic; do
    grep -qE "^CONFIG_PACKAGE_${p}=y$" .config || MISSING="$MISSING $p"
  done
  if [ -n "$MISSING" ]; then
    echo "!! 警告：以下无线包未置 y，固件会「能开机、没有 wifi」："
    for p in $MISSING; do echo "   $p"; done
    echo "   排查：config 里是否误写 =n；FORCE_ON 是否被跳过"
  else
    echo "OK：kmod-mt7615d + luci-app-mtwifi + wpad-basic 齐备"
  fi

  echo "--- [K2P] 开源 mt7615e 复核（必须未选中；与闭源驱动抢同一张卡）---"
  BADC=$(grep -E '^CONFIG_PACKAGE_(kmod-mt7615e|kmod-mt7615-firmware)=[ym]$' .config || true)
  if [ -n "$BADC" ]; then
    echo "$BADC"
    echo "!! 警告：开源 mt7615e 仍在，会与闭源 mt_wifi 抢 PCI 设备"
  else
    echo "OK：开源 kmod-mt7615e / mt7615-firmware 均未选中"
  fi

  echo "--- [K2P] PPPoE 复核（当主路由拨号用）---"
  grep -E '^CONFIG_PACKAGE_(ppp|ppp-mod-pppoe)=' .config || echo "（未选中：本机将无法 PPPoE 拨号，只适合做 AP/旁路由）"

  echo "--- [K2P] 瘦身项复核 ---"
  grep -E '^CONFIG_PACKAGE_(kmod-nf-nathelper-extra|ubi-utils)=' .config || true
fi

# ---------------------------------------------------------------------------
# WR1200JS 专项复核：双芯片开源无线必须在、mt7615 全家不在、dropbear/opkg 不在
# ---------------------------------------------------------------------------
# 同样只「警告不失败」，致命项交给 build.yml 的「配置一致性校验」。
# 本段存在的意义：把三种静默失败在编译日志里喊出来 ——
#   ① 能开机没 wifi（kmod-mt7603 / kmod-mt76x2 被剃）
#   ② mt7615 全家被 DEFAULT_PACKAGES 拉回（白占 ~1MB 且和 wpad-basic 抢 hostapd）
#   ③ dropbear/opkg 没摘掉（用户明确不要，多占 ~160KB 安装）
if echo "$TARGET_CONFIG" | grep -qiE 'wr1200js'; then
  echo "--- [WR1200JS] 开源无线栈复核（必须 =y）---"
  # 只查菜单可选项；kmod-mt76-core / kmod-mt76x2-common 是 HIDDEN:=1，
  # 由 +kmod-xxx 依赖自动 select，硬写 =y 不生效，不该当失败条件。
  MISSING=""
  for p in kmod-mt7603 kmod-mt76x2 kmod-mac80211 kmod-cfg80211 wpad-basic; do
    grep -qE "^CONFIG_PACKAGE_${p}=y$" .config || MISSING="$MISSING $p"
  done
  if [ -n "$MISSING" ]; then
    echo "!! 警告：以下无线包未置 y，固件会「能开机、没有 wifi」："
    for p in $MISSING; do echo "   $p"; done
    echo "   排查：config 里是否误写 =n；DEVICE_PACKAGES 是否被 diy-part2 第 [6/7/8] 段误剔"
  else
    echo "OK：kmod-mt7603 + kmod-mt76x2 + wpad-basic 齐备"
  fi

  echo "--- [WR1200JS] mt7615 全家复核（必须未选中；本机没有该芯片）---"
  BADM=$(grep -E '^CONFIG_PACKAGE_(kmod-mt7615e|kmod-mt7615-firmware|kmod-mt7615d|luci-app-mtwifi)=[ym]$' .config || true)
  if [ -n "$BADM" ]; then
    echo "$BADM"
    echo "!! 警告：mt7615 相关包被选中，本机无此芯片，白占约 1MB，还会与 wpad-basic 抢 hostapd"
  else
    echo "OK：mt7615 全家均未选中"
  fi

  echo "--- [WR1200JS] USB / block-mount 复核（应全部未选中）---"
  BADUSB=$(grep -E '^CONFIG_PACKAGE_(kmod-usb[^=]*|usbutils|usb-modeswitch|libusb[^=]*|block-mount)=[ym]$' .config || true)
  if [ -n "$BADUSB" ]; then
    echo "$BADUSB"
    echo "!! 警告：仍有 USB/挂载包被选中（多为 DEFAULT_PACKAGES.tweak 拉回），体积会比预期略大"
  else
    echo "OK：USB 及 block-mount 全部未选中"
  fi

  echo "--- [WR1200JS] dropbear / opkg 复核（用户要求不要，应未选中）---"
  BADD=$(grep -E '^CONFIG_PACKAGE_(dropbear|opkg)=[ym]$' .config || true)
  if [ -n "$BADD" ]; then
    echo "$BADD"
    echo "!! 警告：dropbear/opkg 仍在 —— 说明 patch-drop-opkg.py 未生效（查 diy-part2 第 [22] 段）"
    echo "   只影响「无 SSH / 多占体积」的预期，不影响固件可启动"
  else
    echo "OK：dropbear / opkg 均未选中"
  fi

  echo "--- [WR1200JS] PPPoE 复核（当主路由拨号用）---"
  grep -E '^CONFIG_PACKAGE_(ppp|ppp-mod-pppoe)=' .config || echo "（未选中：本机将无法 PPPoE 拨号，只适合做 AP/旁路由）"
fi

# ---------------------------------------------------------------------------
# E8821 专项复核：ath10k-ct(smallbuffers) 必须在，其它驱动/固件变体必须不在
# ---------------------------------------------------------------------------
# 这里同样只「警告不失败」——致命项由 CI「校验」段 exit 1。
# 价值在于把三种静默失败提前喊出来：
#   ① 5G 起不来（ath10k-ct 变体选错 / 固件包选成 qca9888）
#   ② 2.4G 没信号（ath9k 被当"无线包"误关）
#   ③ 打包期 PROVIDES 撞车（wpad / kmod-ath10k 两个变体同选）
if echo "$TARGET_CONFIG" | grep -qiE 'zte_e8821'; then
  echo "--- [E8821] 无线栈复核（必须 =y）---"
  MISSING=""
  for p in kmod-ath10k-ct-smallbuffers ath10k-firmware-qca988x-ct kmod-ath9k \
           kmod-mac80211 kmod-cfg80211 wpad-basic-openssl swconfig; do
    grep -qE "^CONFIG_PACKAGE_${p}=y$" .config || MISSING="$MISSING $p"
  done
  if [ -n "$MISSING" ]; then
    echo "!! 警告：以下包未置 y，固件会「能开机、没有 5G」或「2.4G 没信号」："
    for p in $MISSING; do echo "   $p"; done
    echo "   排查：config 里是否误写 =n；FORCE_ON 是否被跳过；diy-part1 的 ath10k 校验是否放行"
  else
    echo "OK：ath10k-ct-smallbuffers + qca988x-ct + ath9k + wpad-basic-openssl + swconfig 齐备"
  fi

  echo "--- [E8821] 同源变体复核（必须未选中，否则打包期 check_data_file_clashes）---"
  # 注意 $ 锚点：'kmod-ath10k-ct' 不能误匹配 'kmod-ath10k-ct-smallbuffers'
  BADC=$(grep -E '^CONFIG_PACKAGE_(kmod-ath10k-ct|kmod-ath10k|ath10k-firmware-qca9888-ct|ath10k-firmware-qca988x)=[ym]$' .config || true)
  if [ -n "$BADC" ]; then
    echo "$BADC"
    echo "!! 警告：存在互斥变体同时选中 —— kmod-ath10k(-ct) 与 -smallbuffers 是同一份源码，"
    echo "   装的是同一批 .ko；qca9888-ct 是 9886/9888 的固件，本机 9882 用不了。"
  else
    echo "OK：regular ath10k / 主线 ath10k / qca9888 固件 / 非 ct 固件 均未选中"
  fi

  echo "--- [E8821] zram 复核（kmod-zram 必须 =y；zram-swap 包应 =n，避免与 [16b] 注入的脚本重复）---"
  grep -E '^CONFIG_PACKAGE_(kmod-zram|zram-swap)=' .config || echo "（kmod-zram 未出现在 .config，[16b] 的 zramswap 将 dry-run 退出）"

  echo "--- [E8821] uboot-envtools 复核（刷 breed，无 U-Boot 环境区，应未选中）---"
  grep -E '^CONFIG_PACKAGE_uboot-envtools=[ym]$' .config && echo "!! 提示：uboot-envtools 仍在，多占 ~45KB（DEVICE_PACKAGES 的 -uboot-envtools 未生效？）" || echo "OK：uboot-envtools 未选中"

  echo "--- [E8821] PPPoE 复核（当主路由拨号用）---"
  grep -E '^CONFIG_PACKAGE_(ppp|ppp-mod-pppoe)=' .config || echo "（未选中：本机将无法 PPPoE 拨号，只适合做 AP/旁路由）"
fi

# ---------------------------------------------------------------------------
# 16MB 机型共用复核：ssr-plus 的 Shadowsocks(libev) 客户端必须在
# ---------------------------------------------------------------------------
# 2026-11-01 起两份 config 都显式选 Libev_Client（ss 协议保留可用）。
# 这里只做提示，不 exit 1 —— 真正致命的判断交给 CI 的「配置一致性校验 / 校验 D」。
# ⚠️ Client 是 kconfig choice：一旦 NONE_Client 与 Libev_Client 同时 =y，
#    解析时只有一个生效，另一个会触发 “out of sync”。
if echo "$TARGET_CONFIG" | grep -qiE 'a3004ns|k2p|wr1200js|zte_e8821'; then
  echo "--- ssr-plus 客户端选型复核（期望 Libev，ss 协议可用）---"
  grep -E '^CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Shadowsocks_(NONE|Libev)_Client=' .config || echo "（choice 尚未落盘）"

  echo "--- ss 协议二进制复核 ---"
  SSMISS=""
  for p in shadowsocks-libev-ss-local shadowsocks-libev-ss-redir libsodium libev \
           dns2socks dns2tcp microsocks shadowsocksr-libev-ssr-check; do
    grep -qE "^CONFIG_PACKAGE_${p}=y$" .config || SSMISS="$SSMISS $p"
  done
  if [ -n "$SSMISS" ]; then
    echo "   (暂未出现，可能尚未 defconfig，属正常)：$SSMISS"
  else
    echo "OK：ss-local / ss-redir / libsodium / libev / dns2socks / dns2tcp / microsocks / ssr-check 全部=y"
  fi
fi
