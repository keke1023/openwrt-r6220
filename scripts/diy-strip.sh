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
fi
