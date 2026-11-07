#!/bin/bash
# HNAT-P2: 在 feeds install 之后、make 之前运行（当前位于 openwrt 源码根目录）
#
# 把「padavanonly/immortalwrt @ master」改造成「A3004NS-dual + MT7621 硬件 NAT +
# 纯有线 + ssr-plus」的形态。五处改动：
#
#   [0] 删掉 helloworld 的 passwall / vssr 与 telephony 的 baresip —— 它们的 Kconfig
#       会触发 recursive dependency，让 make defconfig 丢包（与是否选中无关）
#   [1] 设备树启用 hnat 节点（DSA 变体：mtketh-wan="wan" + mtkdsa-wan-port），不写 ext-devices
#   [2] 内核配置确认 HNAT 为 =m（模块），由 KernelPackage/ramips_hnat 打包进固件
#   [3] 摘掉 mt7621.mk 里 A3004NS 的 DEVICE_PACKAGES（无线 / USB）
#   [4] 默认管理地址改 192.168.9.1，关 fw3 flow_offloading，写 offload 相关 sysctl
#
# ============================================================================
# 关于 [1] 为什么是 DSA 写法，而不是照抄 jcg_q20 的 &hnat 段
# ============================================================================
#   原版 mt7621_iptime_a3004ns-dual.dts 里没有任何 hnat 引用：hnat 节点定义在
#   mt7621.dtsi（compatible = "mediatek,mtk-hnat_v1"，reg 0x1e100000，status="disabled"），
#   机型 dts 不写 &hnat 就永远是 disabled，驱动根本不 probe。所以必须由本脚本追加。
#
#   但 q20 的写法不能直接抄 —— 它是双 gmac 的 swconfig 机型：
#       q20:     mtketh-wan="eth1"  mtketh-lan="eth0"  max-gmac=<2>   （wan 走独立 gmac1）
#   本机 4LAN+1WAN 全挂在内部 MT7530 上，只有一个 gmac0（wan 也在 switch 上），
#   照抄会把 wan 认成 eth1，probe 能过但永远匹配不到流量。
#
#   分支内 13 个启用 HNAT 的机型全是 swconfig（都挂 &gsw 并删 switch0 的 compatible），
#   且**没有一个**用 mtkdsa-wan-port —— 也就是说 DSA 路径在本分支零先例。
#   其中与本机同构（wan 在 switch 上、单 gmac0）的是 newifi-d2 / ghl-r-001：
#       newifi-d2:  mtketh-wan="eth0.2"  mtketh-lan="eth0"  mtketh-ppd="eth0.1"  max-gmac=<1>
#   它们的取值是 swconfig 的 VLAN 子接口名，不是 DSA 的 label。
#
#   本机仍选 DSA 而不是切回 swconfig，因为切换代价会直接断网：
#     · 02_network 里没有 iptime,a3004ns-dual 条目，走默认分支
#         ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4" "wan"
#       —— 这组名字正是 DSA 的 label。改成 swconfig 后只有 eth0.1/eth0.2，
#       默认配置会指向不存在的接口，首次启动直接失联。
#     · mt7621.mk 里该机型带 $(Device/dsa-migration)，官方定位就是 DSA 设备。
#
#   DSA 路径在驱动里是完整的（不是猜的）：
#     · hnat_probe 读属性（hnat.c:718/725/739/747/756）：
#         mtketh-wan / mtketh-lan 是**字符串前缀**，不是完整网口名：
#           IS_LAN(dev) = !strncmp(dev->name, hnat_priv->lan, strlen(...))   hnat.h
#         DSA 下 LAN 口是 lan1..lan4、WAN 是 wan，故填 "lan" / "wan" 即可命中全部。
#     · hnat.c:756 读 mtkdsa-wan-port → wan_dsa_port；!= 0xff 即 hnat_dsa_is_enable()
#       为真（hnat.h:1166），才会在 hnat_nf_hook.c:1523/1536 调 hnat_dsa_fill_stag()。
#     · hnat_stag.c 用 **slave netdev 的 of_node 的 reg 属性**取 DSA 端口号，
#       sp_tag = BIT(port_index)；所以这个值必须等于 wan 在 switch 里的 port@N 的 N。
#       本机 wan = port@0 → <0>（下面会从原 dts 里解析，改板型也不怕写错）。
#     · mtk_eth_soc.c:2669 hw_init 里 netdev_uses_dsa(dev) 为真时置
#       MTK_CDMQ_STAG_EN | MTK_CDMP_STAG_EN —— FE 才会解析 DSA 的 special tag。
#     · max-gmac=<1>：hnat.h:1107 IS_GMAC1_MODE = (gmac_num == 1)，本机只有 gmac0。
#     · mtketh-ppd="eth0"：DSA 的 conduit 设备名（q20 也填 eth0）。它只用于
#       g_ppdev = dev_get_by_name(...)，不参与 DSA 的端口判定。
#
#   ext-devices 整个不写（q20 和其余 12 个机型写的都是 wlan0/ra0/rai0… 这类无线接口）：
#     · 它只对"非 gmac / 非 DSA"的网口做 ext_if 注册，本机无无线、无 USB 网卡；
#     · 缺该属性是安全的：hnat.c 用 of_find_property() 取到 NULL 后交给
#       of_prop_next_string()，后者第一行就是 if (!prop) return NULL（5.10 同样有这个判空）。
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
# [0] 拆掉与本机型无关、却会让 kconfig 报 recursive dependency 的包
#
# 2026-11-07 连续三次 defconfig 被环打断，逐个拆：
#
# 环1（passwall，来自 padavanonly 的 luci feed，18.06-k5.4）：
#     PACKAGE_iptables is selected by PACKAGE_luci-app-passwall_Iptables_Transparent_Proxy
#     → firewall4 → kmod-ipt-nat → kmod-ipt-dnetmap → iptables-mod-dnetmap → iptables
# 环2（telephony feed 的 baresip，自选自己）：
#     baresip-mod-avcodec ↔ baresip-mod-avformat
# 环3（**结构性，与选不选无关**）：
#     PACKAGE_firewall4 depends on !PACKAGE_kmod-ipt-nat     （fw4 的 CONFLICTS）
#     PACKAGE_kmod-ipt-nat default ... if !PACKAGE_firewall4
#
# 环3 是这个分支自己的毛病：include/target.mk 里 DEFAULT_PACKAGES.router 是
#   dnsmasq-full firewall iptables   ← 18.06 时代 fw3 + iptables 的组合，
# 但主仓库里又混进了新版的 package/network/config/firewall4（nftables 方案）。
# 两者在 Kconfig 里互斥，而我们的 ssr-plus 走 Iptables_Transparent_Proxy（要 iptables），
# 三方一碰就成环，被吃掉的正是 luci-app-ssr-plus_Iptables_Transparent_Proxy。
# 本机型不需要 fw4（fw3 才是这分支的默认），直接删目录。
#
# 环是 Kconfig 结构问题，跟「选不选中」无关 —— 只要目录还在 package/ 下就会生成，
# 所以删目录比事后猜「丢了哪几个包」可靠。
# ---------------------------------------------------------------------------
echo "==> [0] 清理会造成 kconfig 循环依赖的无关包"
CLEANED=""
for d in package/network/config/firewall4 \
         package/helloworld/luci-app-passwall \
         package/helloworld/luci-app-passwall2 \
         package/helloworld/luci-app-vssr \
         package/feeds/*/luci-app-passwall \
         package/feeds/*/luci-app-passwall2 \
         package/feeds/*/luci-app-vssr \
         package/feeds/*/baresip \
         package/feeds/*/baresip-*; do
  [ -e "$d" ] || continue
  rm -rf "$d"
  CLEANED="$CLEANED $(basename "$d")"
done
if [ -n "$CLEANED" ]; then
  echo "    已删除：$CLEANED"
else
  echo "   (注意) 没有匹配到任何包 —— feed 结构可能变了，环可能来自别处，看 defconfig 输出"
fi

# 删过头会把命根子删掉，这里立刻验回来
for d in package/helloworld/luci-app-ssr-plus package/helloworld/xray-core; do
  [ -d "$d" ] || { echo "!! 错误：$d 不存在 —— 清理误伤，中止"; exit 1; }
done
echo "    OK：ssr-plus / xray-core 目录完好"

# ---------------------------------------------------------------------------
# [1] 设备树：启用 hnat 节点 + 补齐 hnat_probe 必需的属性
# ---------------------------------------------------------------------------
echo "==> [1] 设备树启用 HNAT（DSA 变体，不带 ext-devices）"

# wan 的 DSA 端口号从原 dts 解析：wan 的 label 上方最近的 port@N 就是答案。
# 解析不到时退回 0（A3004NS-dual 当前就是 port@0），并明确告警。
WAN_DPORT=$(grep -B6 'label = "wan"' "$DTS" | grep -o 'port@[0-9]\+' | tail -1 | tr -dc '0-9')
if [ -z "$WAN_DPORT" ]; then
  WAN_DPORT=0
  echo "   (注意) 未能从 dts 解析 wan 的 port@N，退回 0 —— 请手工确认 &switch0 里 wan 的端口号"
fi
echo "    wan 的 DSA 端口号：port@${WAN_DPORT}"

if grep -q '^&hnat {' "$DTS"; then
  echo "    &hnat 节点已存在，跳过追加（幂等），下面按 DSA 取值逐项核对"
else
  cat >> "$DTS" <<DTS_EOF

/* MT7621 硬件 NAT（HNAT/PPE），DSA 形态
 * mtketh-wan / mtketh-lan 是**名字前缀**：DSA 下命中 wan、lan1..lan4
 * mtketh-max-gmac=<1>：本机只有 gmac0，4LAN+1WAN 全在内部 MT7530 上
 * mtkdsa-wan-port=<${WAN_DPORT}>：让驱动走 hnat_dsa_fill_stag()，否则按 swconfig 的
 *   vlan 规则填 STAG，DSA 设备会转发错端口
 * 不写 ext-devices：无无线/无 USB 网卡，该属性只用于注册外部接口
 */
&hnat {
	mtketh-wan = "wan";
	mtketh-lan = "lan";
	mtketh-ppd = "eth0";
	mtketh-max-gmac = <1>;
	mtkdsa-wan-port = <${WAN_DPORT}>;
	status = "okay";
};
DTS_EOF
  echo "    已追加 &hnat {...}（wan/lan/ppd/max-gmac/mtkdsa-wan-port/status）"
fi

# 逐项回读：每一项都有明确后果，缺一项就不必继续编了
DTS_FAIL=0
need_dts() {
  if grep -qF "$1" "$DTS"; then
    echo "    OK：$1"
  else
    echo "!! 错误：dts 里找不到 [$1]"
    echo "         $2"
    DTS_FAIL=1
  fi
}
need_dts 'mtketh-wan = "wan"'        'hnat.c:718 读不到即 return -EINVAL，probe 直接失败（静默，无加速）'
need_dts 'mtketh-lan = "lan"'        'DSA 下 LAN 是 lan1..lan4，前缀写成 eth0 会一个都匹配不到'
need_dts 'mtketh-ppd = "eth0"'       'ppd 缺省也是 eth0，写出来是为了 dmesg/调试时能一眼看到'
need_dts 'mtketh-max-gmac = <1>'     'hnat.c:747 读不到即 return -EINVAL；值错会让 IS_GMAC1_MODE 取反'
need_dts "mtkdsa-wan-port = <${WAN_DPORT}>" '缺它则 wan_dsa_port=0xff，走 swconfig 的 VLAN/STAG 路径，DSA 下端口必错'
need_dts 'status = "okay"'           'hnat 在 mt7621.dtsi 里默认 disabled，不改就永远不 probe'

if grep -qE 'ext-devices[[:space:]]*=' "$DTS"; then
  echo "   (注意) dts 里出现 ext-devices 属性 —— 本机无无线，若里面是 wlan0/ra0 之类，会注册永不存在的接口"
fi

[ "$DTS_FAIL" = 0 ] || { echo "!! 设备树不符合 HNAT DSA 要求，中止"; exit 1; }
echo "    OK：&hnat 六项齐备，且未引用无线 ext-devices"

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
	dmesg | grep -iE 'mtk-hnat|mtkhnat|wan = |lan = |ppd = |gmac num|dsa port' | tail -10
	echo "  ^ 有 'wan dsa port = N' 才说明走的是 DSA 路径（没有则 wan_dsa_port=0xff，STAG 会按 swconfig 规则填）"
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
