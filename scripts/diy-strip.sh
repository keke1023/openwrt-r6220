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
#   ⚠️ 仅对 a3004ns 生效：dw33d(ath79) 等机型要 wifi，不能全局关 wpad/iwinfo/wireless-regdb。
TARGET_CONFIG="${TARGET_CONFIG:-}"
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
iwinfo \
wireless-regdb \
libiwinfo \
libiwinfo-lua \
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

for p in $FORCE_OFF; do
  sed -i "s/^CONFIG_PACKAGE_${p}=[ym]/CONFIG_PACKAGE_${p}=n/" .config
  grep -q "^CONFIG_PACKAGE_${p}=" .config || echo "CONFIG_PACKAGE_${p}=n" >> .config
done

echo "==> [阶段2] make defconfig（补全新符号，会翻回部分 default y）"
make defconfig

echo "==> [阶段3] defconfig 后再次强制 =n（此时 default y 可被覆盖）"
for p in $FORCE_OFF; do
  sed -i "s/^CONFIG_PACKAGE_${p}=[ym]/CONFIG_PACKAGE_${p}=n/" .config
  grep -q "^CONFIG_PACKAGE_${p}=" .config || echo "CONFIG_PACKAGE_${p}=n" >> .config
done
# USB 通配再扫一次：defconfig 会把 default y 的 block-mount 以及被 select 的 kmod-usb-* 翻回来
if echo "$TARGET_CONFIG" | grep -qiE 'a3004ns'; then
  usb_sweep
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
  BAD=$(grep -E '^CONFIG_PACKAGE_(kmod-mt76|kmod-mac80211|kmod-cfg80211|kmod-mt7602e|kmod-mt7612e|wpad|iwinfo|libiwinfo|wireless-regdb)[^=]*=[ym]' .config || true)
  if [ -n "$BAD" ]; then
    echo "$BAD"
    echo "!! 警告：仍有无线包被选中，实际体积会超 16MB 预算"
  else
    echo "OK：无线相关包全部未选中"
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
  echo "--- [16MB 机型] 内核 USB 开关确认 ---"
  if [ -e build_dir/target-*/linux-*/linux-*/.config ]; then
    grep -E '^CONFIG_USB=|^CONFIG_USB_SUPPORT=|^CONFIG_USB_XHCI' build_dir/target-*/linux-*/linux-*/.config || true
  else
    echo "（内核尚未 configure，编译结束后可复审 build_dir 里的 .config：应无 CONFIG_USB=y/m）"
  fi
fi
