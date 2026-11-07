#!/bin/bash
# HNAT-P2: 在 feeds install 之后、make 之前运行（当前位于 openwrt 源码根目录）
#
# 把「padavanonly/immortalwrt @ master」改造成「A3004NS-dual + MT7621 硬件 NAT +
# 纯有线 + ssr-plus」的形态。四处改动：
#
#   [1] 设备树启用 HNAT 节点（dtsi 里是 status="disabled"）
#   [2] 内核配置把 CONFIG_NET_MEDIATEK_HNAT 从 =m 改成 =y（关键，见下）
#   [3] 摘掉 mt7621.mk 里 A3004NS 的 DEVICE_PACKAGES（无线 / USB）
#   [4] 默认管理地址改 192.168.9.1，并显式关闭 fw3 的 flow_offloading
#
# 关于 [2] 为什么必须改 —— 这是本方案唯一的硬性坑：
#   config-5.10 里写的是 CONFIG_NET_MEDIATEK_HNAT=m，但它**没有任何
#   KernelPackage 定义**（已核对 package/kernel/linux/modules/*.mk 与
#   target/linux/ramips/Makefile，均无 mtkhnat 条目）。OpenWrt 的规则是：
#   只有被 KernelPackage 声明的 =m 符号才会被打进固件，其余 =m 编出来的 .ko
#   在打包阶段直接丢弃 —— 表现为「编译通过、固件里没有 mtkhnat.ko、HNAT 不生效」，
#   而且不会有任何报错。改成 =y 内建即可绕过打包环节。
#   内建是安全的：hnat.c 用 module_platform_driver()，靠 dts 的 hnat 节点 probe，
#   内建时 module_init 变 device_initcall，与 =m 走同一条 probe 路径。

TARGET_CONFIG="${TARGET_CONFIG:-}"
DTS="target/linux/ramips/dts/mt7621_iptime_a3004ns-dual.dts"
KCFG="target/linux/ramips/mt7621/config-5.10"
MK="target/linux/ramips/image/mt7621.mk"

for f in "$DTS" "$KCFG" "$MK"; do
  [ -f "$f" ] || { echo "!! 错误：缺少 $f —— 源码树与预期不符，中止"; exit 1; }
done

# ---------------------------------------------------------------------------
# [1] 设备树：启用 hnat 节点
#
# mt7621.dtsi 里定义：
#   hnat: hnat@1e100000 { compatible = "mediatek,mtk-hnat_v1"; reg = <0x1e100000 0x3000>;
#                         resets = <&ethsys 0>; reset-names = "mtketh"; status = "disabled"; };
# 设备 dts 里追加 &hnat { status = "okay"; } 即覆盖为启用。
# 注意 dts 语法：追加段落必须独立、以 ; 结尾，且不能写在 / { } 内部。
# ---------------------------------------------------------------------------
echo "==> [1] 设备树启用 HNAT"
if grep -q '^&hnat {' "$DTS"; then
  echo "    &hnat 节点已存在，跳过（幂等）"
else
  cat >> "$DTS" <<'DTS_EOF'

&hnat {
	status = "okay";
};
DTS_EOF
  echo "    已追加 &hnat { status = \"okay\"; }"
fi
if ! grep -q '^&hnat {' "$DTS"; then
  echo "!! 错误：&hnat 节点注入失败，HNAT 不会 probe"
  exit 1
fi

# ---------------------------------------------------------------------------
# [2] 内核配置：HNAT 由模块改内建
# ---------------------------------------------------------------------------
echo "==> [2] 内核配置强制 HNAT 内建"
HNAT_CUR=$(grep -E '^CONFIG_NET_MEDIATEK_HNAT=' "$KCFG" | head -1)
echo "    改前：${HNAT_CUR:-（未定义）}"
if [ "$HNAT_CUR" = "CONFIG_NET_MEDIATEK_HNAT=y" ]; then
  echo "    已是 =y，跳过"
else
  if grep -q '^CONFIG_NET_MEDIATEK_HNAT=' "$KCFG"; then
    sed -i 's/^CONFIG_NET_MEDIATEK_HNAT=.*/CONFIG_NET_MEDIATEK_HNAT=y/' "$KCFG"
  else
    # 符号缺失时补一行（正常不会走到这里）
    echo 'CONFIG_NET_MEDIATEK_HNAT=y' >> "$KCFG"
  fi
  echo "    改后：$(grep -E '^CONFIG_NET_MEDIATEK_HNAT=' "$KCFG" | head -1)"
fi
if ! grep -q '^CONFIG_NET_MEDIATEK_HNAT=y$' "$KCFG"; then
  echo "!! 错误：HNAT 未改成内建 —— =m 不会被 KernelPackage 打包，固件里不会有它"
  exit 1
fi

# 顺带确认 MTK SDK 驱动与 DSA tag 都在（HNAT 的 STAG 依赖 CONFIG_NET_DSA_MT7530）
for sym in CONFIG_NET_MTKSDK=y CONFIG_NET_DSA=y CONFIG_NET_DSA_MT7530=y CONFIG_NET_DSA_TAG_MTK=y; do
  grep -q "^${sym}$" "$KCFG" || echo "   (注意) $KCFG 里没有 $sym —— HNAT 可能无法工作"
done

# ---------------------------------------------------------------------------
# [3] 摘掉 A3004NS 的 DEVICE_PACKAGES（无线 / USB）
#
# 原值：DEVICE_PACKAGES := kmod-usb3 kmod-mt76x2 kmod-usb-ledtrig-usbport
# DEVICE_PACKAGES 是「强制加入」语义，config 里写 =n 压不住它 —— 必须在这里改。
# 全部清空：无 USB、无无线，正好符合本机型定位（纯有线代理网关）。
# ---------------------------------------------------------------------------
echo "==> [3] 清空 A3004NS 的 DEVICE_PACKAGES"
echo "    改前：$(sed -n '/define Device\/iptime_a3004ns-dual/,/^endef/p' "$MK" | grep 'DEVICE_PACKAGES' | head -1 | sed 's/^ *//')"
sed -i '/define Device\/iptime_a3004ns-dual/,/^endef/s/^[[:space:]]*DEVICE_PACKAGES[[:space:]]*:=.*/  DEVICE_PACKAGES :=/' "$MK"
DP_AFTER=$(sed -n '/define Device\/iptime_a3004ns-dual/,/^endef/p' "$MK" | grep 'DEVICE_PACKAGES' | head -1)
echo "    改后：$(echo "$DP_AFTER" | sed 's/^ *//')"
if [ -n "$DP_AFTER" ] && ! echo "$DP_AFTER" | grep -qE 'DEVICE_PACKAGES[[:space:]]*:=[[:space:]]*$'; then
  echo "!! 错误：DEVICE_PACKAGES 未清空（仍有内容），无线/USB 包会被强制拉回"
  exit 1
fi
echo "    OK：kmod-mt76x2 / kmod-usb3 / kmod-usb-ledtrig-usbport 已从设备定义移除"

# ---------------------------------------------------------------------------
# [4] 默认管理地址 + 关闭 fw3 flow_offloading
#
# 地址：本机所在网段是 192.168.9.0/24（上游路由在 192.168.1.1），
#       沿用 192.168.9.1 可与现有环境无缝替换。
#
# flow_offloading：fw3 的 flowtable 软件卸载与 HNAT 走的是同一条转发加速路径，
#   两套同时开只会互相干扰（且软件档在 MT7621 上省不了多少 CPU）。
#   本方案只留 HNAT，故显式置 0 —— 用 uci-defaults 而不是改 firewall.config，
#   这样 sysupgrade 保留旧 /etc/config 时也能覆盖到。
# ---------------------------------------------------------------------------
echo "==> [4] 默认管理地址与 offload 策略"
CG="package/base-files/files/bin/config_generate"
if [ -f "$CG" ]; then
  sed -i 's/192\.168\.1\.1/192.168.9.1/g' "$CG"
  echo "    默认 LAN 地址 -> 192.168.9.1（已改 config_generate）"
else
  echo "   (注意) 未找到 $CG，默认地址可能仍是 192.168.1.1"
fi

mkdir -p files/etc/uci-defaults
cat > files/etc/uci-defaults/99-hnat-defaults <<'UCI_EOF'
#!/bin/sh
# HNAT 机型首次启动执行一次（uci-defaults 机制执行后自动删除）
# 关掉 fw3 的 flowtable 卸载：转发加速统一交给 MT7621 的 HNAT/PPE
uci -q set firewall.@defaults[0].flow_offloading='0'
uci -q set firewall.@defaults[0].flow_offloading_hw='0'
uci -q commit firewall
exit 0
UCI_EOF
chmod +x files/etc/uci-defaults/99-hnat-defaults
echo "    已注入 files/etc/uci-defaults/99-hnat-defaults（flow_offloading=0）"

echo "==> HNAT-P2 完成"
