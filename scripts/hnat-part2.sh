#!/bin/bash
# HNAT-P2: 在 feeds install 之后、make 之前运行（当前位于 openwrt 源码根目录）
#
# 把「padavanonly/immortalwrt @ master」改造成「A3004NS-dual + MT7621 硬件 NAT +
# 纯有线 + ssr-plus」的形态。四处改动：
#
#   [1] 设备树启用 hnat 节点，并补齐 hnat_probe() 强制要求的属性
#   [2] 内核配置确认 HNAT 为 =m（模块），由 KernelPackage/ramips_hnat 打包进固件
#   [3] 摘掉 mt7621.mk 里 A3004NS 的 DEVICE_PACKAGES（无线 / USB）
#   [4] 默认管理地址改 192.168.9.1，关 fw3 flow_offloading，写 offload 相关 sysctl
#
# ============================================================================
# 关于 [1] 为什么不能只写 status="okay"
# ============================================================================
#   hnat.c 的 hnat_probe() 里前两个读属性都是**硬失败**：
#       hnat.c:718  of_property_read_string(np, "mtketh-wan", &name);   err<0 → return -EINVAL
#       hnat.c:747  of_property_read_u32_index(np, "mtketh-max-gmac", 0, &val); err<0 → return -EINVAL
#   只要这两个缺一个，probe 直接失败：dmesg 一句 "mtk-hnat: probe failed"，
#   /sys/kernel/debug/hnat 不存在，转发全走软件路径，而且**没有任何其它报错**。
#   其余属性有默认值，但默认值对本案是错的（默认 lan="eth0"、max-gmac 无默认）。
#
#   属性取值依据（不是猜的）：
#     · 本机是 DSA：dts 里 &switch0 的 port@0 label="wan"、port@1..4 label="lan1..4"
#     · hnat.h:1139-1142 用**前缀匹配**判 DSA 网口：
#           IS_DSA_LAN(dev)  = !strncmp(dev->name, "lan", 3)
#           IS_DSA_WAN(dev)  = !strncmp(dev->name, "wan", 3)
#           IS_WAN(dev)      = !strncmp(dev->name, hnat_priv->wan, strlen(...))
#           IS_LAN(dev)      = !strncmp(dev->name, hnat_priv->lan, strlen(...))
#       所以 mtketh-wan="wan"、mtketh-lan="lan" 就能同时匹配 wan 与 lan1-4。
#     · hnat.h:1107  IS_GMAC1_MODE = (gmac_num == 1) —— 本机 4LAN+1WAN 全挂在内部
#       MT7530 上，只用 gmac0 一个口，故 max-gmac = <1>。
#     · mtkdsa-wan-port 只是**开关**（hnat.h:1166 hnat_dsa_is_enable() 判 != 0xff）：
#       有它才会走 hnat_dsa_fill_stag()，让 FE 按 DSA 端口号生成 STAG；
#       没有它则按 swconfig 的 vpm/vlan 规则处理 —— 对 DSA 设备是错的。
#       值取 wan 的 DSA 端口号（port@0 → 0），实际只用于 dmesg 打印。
#     · mtketh-ppd 在无外设（无 wifi/USB 网卡）时只在 do_hnat_ext_to_ge() 里用到，
#       那条路要求 ext-devices 存在；本机不写 ext-devices，故它不影响转发。
#       仍填 eth0（DSA 的 conduit），避免 g_ppdev 为 NULL 时的空指针疑虑。
#
# ============================================================================
# 关于 [2] 为什么是「确认 =m」而不是「强制 =y」（这是上一版写错的地方）
# ============================================================================
#   早先判断「全仓库没有 KernelPackage 定义 mtkhnat，=m 编出的 .ko 会被丢弃」——
#   **这个判断是错的**，因为只查了 package/kernel/linux/modules/*.mk，漏了 target 侧。
#   target/linux/ramips/modules.mk:137 实际有：
#       define KernelPackage/ramips_hnat
#         DEPENDS:=@TARGET_ramips +kmod-nf-conntrack
#         KCONFIG:= CONFIG_BRIDGE_NETFILTER=y CONFIG_NETFILTER_FAMILY_BRIDGE=y
#         FILES:= $(LINUX_DIR)/drivers/net/ethernet/mediateksdk/mtk_hnat/mtkhnat.ko
#       endef
#   所以正确的做法就是保留 =m、在 .config 里选 kmod-ramips_hnat=y。
#
#   为什么坚持模块而不是内建：
#     · 分支自带的 mtkhqos 工具就是 `modprobe mtkhnat` 加载的，作者按模块设计；
#     · HNAT 会绕过 netfilter 做 FOE 卸载，一旦与 ssr-plus 的 TPROXY 打架，
#       能 `rmmod mtkhnat` 立刻退回软件转发（脚本里带 hnat-ctl 方便操作），
#       内建就得重刷固件；
#     · 内建时 KernelPackage 的 install 钩子只会打一行 "module is built-in" NOTICE，
#       不会报错 —— 也就是说内建即使「看着成功」，也无法从 .manifest 侧验证；
#       而模块形态可以用 .manifest 精确确认它真的进了固件。
#
#   CONFIG_KERNEL_* 是真生效的：include/kernel-defaults.mk:108 会把 .config 里的
#   CONFIG_KERNEL_X 改写成 CONFIG_X 追加到 .config.target，覆盖 config-5.10 的默认值。
#   所以这里要保证 config-5.10 和 .config 两侧都不出现 =y。

TARGET_CONFIG="${TARGET_CONFIG:-}"
DTS="target/linux/ramips/dts/mt7621_iptime_a3004ns-dual.dts"
KCFG="target/linux/ramips/mt7621/config-5.10"
MK="target/linux/ramips/image/mt7621.mk"
RMOD="target/linux/ramips/modules.mk"

for f in "$DTS" "$KCFG" "$MK" "$RMOD"; do
  [ -f "$f" ] || { echo "!! 错误：缺少 $f —— 源码树与预期不符，中止"; exit 1; }
done

# ---------------------------------------------------------------------------
# [1] 设备树：启用 hnat 节点 + 补齐 hnat_probe 必需的属性
# ---------------------------------------------------------------------------
echo "==> [1] 设备树启用 HNAT（含必需属性）"
if grep -q '^&hnat {' "$DTS"; then
  echo "    &hnat 节点已存在，跳过（幂等）"
else
  cat >> "$DTS" <<'DTS_EOF'

/* MT7621 硬件 NAT（HNAT/PPE）
 * mtketh-wan / mtketh-max-gmac 是 hnat_probe() 的硬性要求，缺任一即 probe 失败；
 * mtkdsa-wan-port 是「启用 DSA STAG 路径」的开关，缺了会按 swconfig 的 VLAN 规则处理。
 * 本机 4LAN+1WAN 全部挂在内部 MT7530 上（DSA），wan 是 port@0。
 */
&hnat {
	mtketh-wan = "wan";
	mtketh-lan = "lan";
	mtketh-ppd = "eth0";
	mtketh-max-gmac = <1>;
	mtkdsa-wan-port = <0>;
	status = "okay";
};
DTS_EOF
  echo "    已追加 &hnat {...}（wan/lan/ppd/max-gmac/mtkdsa-wan-port/status）"
fi

# 四个必需属性逐项回读：任何一个没落地，都不必继续编了
for p in 'mtketh-wan' 'mtketh-max-gmac' 'mtkdsa-wan-port' 'status = "okay"'; do
  if grep -q "$p" "$DTS"; then
    echo "    OK：$p"
  else
    echo "!! 错误：&hnat 节点缺 $p —— hnat_probe() 会失败，硬件加速不会生效"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# [2] 内核配置：HNAT 必须是 =m，并由 KernelPackage/ramips_hnat 打包
# ---------------------------------------------------------------------------
echo "==> [2] 内核配置确认 HNAT 为模块"
# 先确认 KernelPackage 还在（分支 rebase 后若被删掉，这里立刻失败，而不是编出一个没驱动的固件）
if ! grep -q 'KernelPackage/ramips_hnat' "$RMOD"; then
  echo "!! 错误：$RMOD 里没有 KernelPackage/ramips_hnat，mtkhnat.ko 无法打包"
  exit 1
fi
echo "    OK：KernelPackage/ramips_hnat 存在（target/linux/ramips/modules.mk）"

HNAT_CUR=$(grep -E '^CONFIG_NET_MEDIATEK_HNAT=' "$KCFG" | head -1)
echo "    config-5.10 现状：${HNAT_CUR:-（未定义）}"
if [ "$HNAT_CUR" = "CONFIG_NET_MEDIATEK_HNAT=y" ]; then
  # 上一版脚本会把它改成 =y；这里反向纠回 =m，保证模块可打包
  sed -i 's/^CONFIG_NET_MEDIATEK_HNAT=.*/CONFIG_NET_MEDIATEK_HNAT=m/' "$KCFG"
  echo "    已纠正回 =m（内建形态无法 rmmod 回退）"
fi
if ! grep -q '^CONFIG_NET_MEDIATEK_HNAT=m$' "$KCFG"; then
  echo "!! 错误：config-5.10 里 HNAT 不是 =m（当前：$(grep -E '^CONFIG_NET_MEDIATEK_HNAT=' "$KCFG" | head -1)）"
  echo "         =m + kmod-ramips_hnat 才既有 .ko 又可 rmmod"
  exit 1
fi
echo "    OK：CONFIG_NET_MEDIATEK_HNAT=m"

# MTK SDK 驱动与 DSA 支持是 HNAT 的硬依赖（STAG 走 netdev_uses_dsa 分支）
for sym in CONFIG_NET_MTKSDK=y CONFIG_NET_DSA=y CONFIG_NET_DSA_MT7530=y; do
  if grep -q "^${sym}$" "$KCFG"; then
    echo "    OK：$sym"
  else
    echo "!! 错误：$KCFG 缺少 $sym —— SDK 驱动或 DSA/STAG 不在，HNAT 无法工作"
    exit 1
  fi
done

# 开机自动加载 mtkhnat（KernelPackage 里没有 AUTOLOAD，必须自带 modules.d 条目）
mkdir -p files/etc/modules.d
echo "mtkhnat" > files/etc/modules.d/60-mtkhnat
echo "    已注入 files/etc/modules.d/60-mtkhnat（开机加载 mtkhnat）"

# 运行期开关：HNAT 一旦和代理/转发打架，ssh 进 LAN 口仍可用，直接 hnat-ctl stop 回退
mkdir -p files/usr/sbin
cat > files/usr/sbin/hnat-ctl <<'CTL_EOF'
#!/bin/sh
# MT7621 HNAT 运行期开关（模块形态才有意义；内建时 stop 会失败）
#   hnat-ctl status   看模块 / debugfs / FOE 表 / 已卸载条目数
#   hnat-ctl stop     rmmod mtkhnat，转发退回软件路径（不影响本机 ssh）
#   hnat-ctl start    modprobe mtkhnat
d=/sys/kernel/debug/hnat
case "$1" in
start)
	modprobe mtkhnat && echo "mtkhnat loaded" || echo "modprobe failed"
	;;
stop)
	rmmod mtkhnat && echo "mtkhnat removed" || echo "rmmod failed"
	;;
status|*)
	echo "== module =="
	grep -E '^mtkhnat ' /proc/modules || echo "  (not loaded)"
	echo "== probe(dmesg) =="
	dmesg | grep -iE 'mtk-hnat|mtkhnat|wan = |lan = |gmac num' | tail -8
	echo "== debugfs =="
	if [ -d "$d" ]; then
		echo "  $d 存在"
		echo "  version : $(cat $d/hnat_version 2>/dev/null)"
		echo "  entry   : $(grep -c . $d/all_entry 2>/dev/null) 行"
		echo "  setting : $(head -1 $d/hnat_setting 2>/dev/null)"
	else
		echo "  $d 不存在（HNAT 未生效）"
	fi
	;;
esac
CTL_EOF
chmod +x files/usr/sbin/hnat-ctl
echo "    已注入 files/usr/sbin/hnat-ctl（status/stop/start）"

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
DP_VAL=$(echo "$DP_AFTER" | sed -e 's/^[[:space:]]*DEVICE_PACKAGES[[:space:]]*:=[[:space:]]*//' -e 's/[[:space:]]*$//')
echo "    改后：DEVICE_PACKAGES := ${DP_VAL:-（空）}"
if [ -n "$DP_VAL" ]; then
  echo "!! 错误：DEVICE_PACKAGES 未清空（仍有内容：$DP_VAL），无线/USB 包会被强制拉回"
  exit 1
fi
echo "    OK：kmod-mt76x2 / kmod-usb3 / kmod-usb-ledtrig-usbport 已从设备定义移除"

# ---------------------------------------------------------------------------
# [4] 默认管理地址 + flow_offloading 策略 + offload 相关 sysctl
#
# 地址：本机所在网段是 192.168.9.0/24（上游路由在 192.168.1.1），
#       沿用 192.168.9.1 可与现有环境无缝替换。
#
# flow_offloading：fw3 的 flowtable 软件卸载与 HNAT 走的是同一条转发加速路径，
#   两套同时开只会互相干扰（且软件档在 MT7621 上省不了多少 CPU）。
#   本方案只留 HNAT，故显式置 0 —— 用 uci-defaults 而不是改 firewall.config，
#   这样 sysupgrade 保留旧 /etc/config 时也能覆盖到。
#
# bridge-nf-call-*：这条是分支自带 mtkhqos 脚本里的做法（它注释写
#   "disable bridge netfilter module to avoid high cpu usage"）。
#   HNAT 卸载后的包直接由 PPE 转发、不再进 netfilter，如果还开着桥接层的
#   netfilter 调用，桥接帧会被强行提上协议栈，把卸载省下的 CPU 又吃回去。
#   本机无无线，LAN↔LAN 的桥接过滤用不上；LAN→WAN 是路由转发，走 IP 栈的
#   PREROUTING，不受影响，所以 ssr-plus 的分流规则照常生效。
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

# 关掉桥接层的 netfilter 调用（同分支 mtkhqos 的做法）：HNAT 卸载的包不过
# netfilter，桥接 netfilter 只会把已卸载的流量重新拉回协议栈。
# LAN→WAN 是路由转发，不走桥接路径，ssr-plus 分流不受影响。
if [ -d /proc/sys/net/bridge ]; then
	echo 0 > /proc/sys/net/bridge/bridge-nf-call-arptables
	echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables
	echo 0 > /proc/sys/net/bridge/bridge-nf-call-ip6tables
	echo 0 > /proc/sys/net/bridge/bridge-nf-filter-pppoe-tagged 2>/dev/null
	echo 0 > /proc/sys/net/bridge/bridge-nf-filter-vlan-tagged 2>/dev/null
fi
# conntrack 容量：HNAT 只是把已建立的流卸载，首包仍需建 conntrack，
# 代理场景连接多，给足桶大小避免 table full
echo 32768 > /proc/sys/net/netfilter/nf_conntrack_buckets 2>/dev/null
echo 16384 > /proc/sys/net/netfilter/nf_conntrack_expect_max 2>/dev/null

# 中断均衡：把网卡中断从 CPU0 分散到 4 核（HNAT 只管已卸载流量，
# 首包/代理/UDP 仍走 CPU，irqbalance 对这部分有实际收益）
if [ -x /etc/init.d/irqbalance ]; then
	/etc/init.d/irqbalance enable
	/etc/init.d/irqbalance start
fi
exit 0
UCI_EOF
chmod +x files/etc/uci-defaults/99-hnat-defaults
sh -n files/etc/uci-defaults/99-hnat-defaults || { echo "!! 99-hnat-defaults 语法错误"; exit 1; }
echo "    已注入 files/etc/uci-defaults/99-hnat-defaults（flow_offloading=0 + bridge-nf + conntrack）"

echo "==> HNAT-P2 完成"
