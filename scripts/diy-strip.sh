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
