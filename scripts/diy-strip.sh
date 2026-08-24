#!/bin/bash
# DIY-STRIP: 在 make defconfig 之后运行（当前位于 openwrt 源码根目录，.config 已生成）
#
# 作用：强制剔除「默认全家桶」包与 openssl 链，确保 16MB SPI 不被撑爆。
#
# 背景：immortalwrt 的 default-settings-chn / DEFAULT_PACKAGES.tweak 用 default y 甚至
#       select 把一批 LuCI 应用（diskman / passwall / rclone / turboacc）和 openssl 链
#       默认拽入。在 config-*.config 里写 =n 仍可能被 select 覆盖（实测 turboacc 的
#       TURBOACC_INCLUDE_* 子项 defconfig 后仍 =y），故必须在 defconfig 之后用 sed 强制
#       =n 并重新 defconfig 固化。
#
# 剔除清单（对「vless+reality + ngrokc」最小目标均非必需）：
#   - luci-app-diskman(+INCLUDE_btrfs_progs/lsblk)：无 USB/存储
#   - luci-app-passwall(+INCLUDE_*)：与 ssr-plus 重复
#   - luci-app-rclone(+INCLUDE_*)：网盘，不需要
#   - luci-app-turboacc(+TURBOACC_INCLUDE_*)：NAT offload，xray 用户态无增益
#   - openssl 链：仅保留 mbedtls 后端（libustream-mbedtls=y 已在 config 选），
#     去掉 libustream-openssl / libopenssl / wpad-basic-openssl（退回 mbedtls 版 wpad），
#     否则 openssl ~1MB 被 ssr-plus 的 INCLUDE_libustream-openssl 拉回。

echo "==> 强制剔除默认全家桶与 openssl 链（16MB SPI 精简）"

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
  # 把任意已存在的 =y/=m 改成 =n；不存在则追加 =n（重新 defconfig 后按需生效）
  sed -i "s/^CONFIG_PACKAGE_${p}=[ym]/CONFIG_PACKAGE_${p}=n/" .config
  grep -q "^CONFIG_PACKAGE_${p}=" .config || echo "CONFIG_PACKAGE_${p}=n" >> .config
done

# wpad-basic-openssl 去掉后，让 defconfig 选回默认 wpad-basic（mbedtls 或无加密版）
sed -i '/^CONFIG_PACKAGE_wpad-basic-openssl=/d' .config
echo "CONFIG_PACKAGE_wpad-basic=m" >> .config

# 重新 defconfig 固化强制 =n
make defconfig

echo "==> 全家桶剔除完成，复核关键包状态："
grep -E 'luci-app-diskman|luci-app-passwall|luci-app-rclone|luci-app-turboacc|libopenssl|libustream-openssl|wpad-basic' .config | head -20
