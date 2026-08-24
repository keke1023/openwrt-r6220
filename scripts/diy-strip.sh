#!/bin/bash
# DIY-STRIP: 在 make defconfig 之后运行（当前位于 openwrt 源码根目录，.config 已生成）
#
# 作用：强制剔除「默认全家桶」包与 openssl 链，确保 16MB SPI 不被撑爆。
#
# 背景：immortalwrt 的 default-settings-chn / DEFAULT_PACKAGES.tweak 用 default y 甚至
#       select 把一批 LuCI 应用（diskman / passwall / rclone / turboacc）和 openssl 链
#       默认拽入。在 config-*.config 里写 =n 仍可能被 select 覆盖（实测 turboacc 的
#       TURBOACC_INCLUDE_* 子项 defconfig 后仍 =y），故必须在 defconfig 之后用 sed 强制
#       =n。
#
# ⚠️ 关键陷阱（实测踩过）：
#   - `make defconfig` 会把 default y 的包翻回 =y，会把阶段1的 =n 废掉。
#   - 因此采用「两阶段 sed」：阶段1 sed =n → 阶段2 defconfig 补全新符号 →
#     阶段3 再次 sed =n（此时 default y 的能被显式 =n 覆盖；select 的若已无 select 源
#     也能压住）→ 阶段4 不跑 defconfig，直接交棒给后续 make（make 会自动 oldconfig 补全，
#     但不会把已显式 =n 的翻回）。
#   - openssl 链是硬依赖：wpad-basic-openssl / luci-lib-nixio_openssl / ssr-plus 的
#     INCLUDE_libustream-openssl 都 select libopenssl。只要这三个 =n，libopenssl 就失去
#     所有 select 源，自身 =n 即可生效。故阶段1必须把这三个父包也 =n。

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
libustream-openssl \
libopenssl \
libopenssl-conf \
wpad-basic-openssl \
luci-app-ssr-plus_INCLUDE_libustream-openssl \
luci-lib-nixio_openssl \
chinadns-ng \
microsocks \
dns2socks \
dns2tcp \
"

for p in $FORCE_OFF; do
  sed -i "s/^CONFIG_PACKAGE_${p}=[ym]/CONFIG_PACKAGE_${p}=n/" .config
  grep -q "^CONFIG_PACKAGE_${p}=" .config || echo "CONFIG_PACKAGE_${p}=n" >> .config
done

# wpad-basic-openssl 去掉后，显式选回基础版 wpad-basic（mbedtls/无 TLS，家用 WPA2 足够）
sed -i '/^CONFIG_PACKAGE_wpad-basic-openssl=/d' .config
grep -q '^CONFIG_PACKAGE_wpad-basic=' .config || echo "CONFIG_PACKAGE_wpad-basic=m" >> .config

echo "==> [阶段2] make defconfig（补全新符号，会翻回部分 default y）"
make defconfig

echo "==> [阶段3] defconfig 后再次强制 =n（此时 default y 可被覆盖；openssl 链已无 select 源）"
for p in $FORCE_OFF; do
  sed -i "s/^CONFIG_PACKAGE_${p}=[ym]/CONFIG_PACKAGE_${p}=n/" .config
  grep -q "^CONFIG_PACKAGE_${p}=" .config || echo "CONFIG_PACKAGE_${p}=n" >> .config
done
sed -i '/^CONFIG_PACKAGE_wpad-basic-openssl=/d' .config
grep -q '^CONFIG_PACKAGE_wpad-basic=' .config || echo "CONFIG_PACKAGE_wpad-basic=m" >> .config

echo "==> [阶段4] 不重跑 defconfig，直接复核关键包状态："
echo "--- 期望全为 =n ---"
grep -E 'luci-app-diskman|luci-app-passwall|luci-app-rclone|luci-app-turboacc|libopenssl|libustream-openssl|wpad-basic-openssl|chinadns-ng|microsocks|dns2socks|dns2tcp|luci-lib-nixio_openssl|luci-app-ssr-plus_INCLUDE_libustream-openssl' .config
echo "--- wpad 实际选型 ---"
grep -E '^CONFIG_PACKAGE_wpad' .config
