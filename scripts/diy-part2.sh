#!/bin/bash
# DIY-P2: 在 make defconfig 之后、make 之前运行（当前位于 openwrt 源码根目录）
# 作用：修改固件默认行为（管理地址、主机名、时区等）。

# 1) 修改默认管理地址为 192.168.6.1（替换 OpenWrt 默认的 192.168.1.1）
echo "==> 设置默认管理地址为 192.168.6.1"
sed -i 's/192.168.1.1/192.168.6.1/g' package/base-files/files/bin/config_generate

# 2) 可选：设置默认时区为 CST-8（取消注释生效）
# sed -i "s/'UTC'/'CST-8'/g" package/base-files/files/bin/config_generate

# 3) 可选：设置默认主机名（取消注释生效）
# sed -i "s/'OpenWrt'/'R6220'/g" package/base-files/files/bin/config_generate

# 4) 可选：设置默认 root 密码（取消注释，把 YOUR_PASSWORD 换成你自己的）
# sed -i 's/$1$V4UetPzk$CYXluq4wUazHjmCDBCqXF.//YOUR_PASSWORD_HASH/g' package/base-files/files/etc/shadow

# 6/7/8) ramips/mt7621 设备 USB（及 A3004NS 无线）剔除
#    这些设备的 USB/无线包写在 DEVICE_PACKAGES 里（.config 删不掉），必须改源码 mk。
#    ⚠️ 旧实现用全局 sed/replace，会跨块误伤其他设备（尤其 tab 续行且 USB 包紧邻 endef 的设备，
#       会把续行反斜杠或 endef 前的换行破坏 → "missing 'endef', unterminated 'define'"）。
#    现改用【块级解析】：精确配对 define Device/<x> ... endef，只在目标块内剔除指定包，
#    绝不碰 endef，也不影响其他设备；最后做 define/endef 数量自检。
MT7621_MK="target/linux/ramips/image/mt7621.mk"
if [ -f "$MT7621_MK" ]; then
  echo "==> 块级剔除 mt7621 设备默认 USB/无线包（行级 token 删除，保留 define/endef，不影响其他设备）"
  python3 - "$MT7621_MK" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

jobs = [
    # dev, [要剔除的包]  —— 保留各自无线/父类包
    ("youhua_wr1200js",     ["kmod-usb3", "kmod-usb-ledtrig-usbport"]),                 # 续行格式，保留 mt7603/mt76x2
    ("dlink_dir-882-a1",    ["kmod-usb3", "kmod-usb-ledtrig-usbport"]),                 # 单行 +=，保留 mt7615e(父类)
    ("iptime_a3004ns-dual", ["kmod-usb3", "kmod-mt76x2", "kmod-usb-ledtrig-usbport"]),  # 单行 :=，去 USB+无线，纯有线
]

def remove_pkg(ln, pkg):
    # 朴素字符串删除：覆盖 "pkg" / "pkg \" (续行) / " pkg" / "\tpkg" 等形态
    for variant in [pkg, pkg + " \\", pkg + "\\", " " + pkg, "\t" + pkg]:
        ln = ln.replace(variant, "")
    # 清掉行尾可能残留的孤立续行反斜杠
    return ln.rstrip().rstrip("\\").rstrip()

# 续行安全：先把块内以 \ 结尾的续行合并成逻辑单行，再删包，避免留下悬挂 TAB 行。
# 旧实现逐行删包：若 "DEVICE_PACKAGES := usb-pkg \" 在续行上一行、保留包在下一行，
# 删 usb 后上一行变空被丢弃、下一行残留 TAB 包 -> eval 时报
# "recipe commences before first target"（正是 Makefile:234 那类错）。
for dev, pkgs in jobs:
    key = "define Device/%s" % dev
    if key not in s:
        print("  (skip %s: 不在 mt7621.mk)" % dev); continue
    lines = s.split("\n")
    in_block = False; start = end = -1
    for i, ln in enumerate(lines):
        if ln.startswith(key):
            in_block = True; start = i; continue
        if in_block and ln == "endef":
            end = i; break
    if start < 0 or end < 0:
        print("  (skip %s: 块边界未找到)" % dev); continue
    # 1) 合并续行：把以 \ 结尾的行的下一行并入（去掉上一行尾部 \，拼接本行内容）
    buf = []
    for j in range(start, end):
        ln = lines[j]
        if buf and buf[-1].rstrip().endswith("\\"):
            prev = buf[-1].rstrip()[:-1].rstrip()
            buf[-1] = prev + " " + ln.strip()
        else:
            buf.append(ln)
    # 2) 在逻辑单行上删包，丢弃变空的行（不再产生悬挂 TAB 行）
    out = []
    for ln in buf:
        new = ln
        for pkg in pkgs:
            new = remove_pkg(new, pkg)
        if new.strip() in ("", "\t", "\\", "DEVICE_PACKAGES", "DEVICE_PACKAGES :="):
            continue
        out.append(new)
    lines[start:end] = out
    s = "\n".join(lines)
    print("  patched %s: 移除 %s" % (dev, ", ".join(pkgs)))

open(p, "w", encoding="utf-8").write(s)

# 自检：所有 define 类型与 endef 必须配对（mk 语法硬性要求）
all_define = len(re.findall(r"^define ", s, re.M))
all_endef  = len(re.findall(r"^endef", s, re.M))
print("SELFCHECK define=%d endef=%d" % (all_define, all_endef))
if all_define != all_endef:
    print("!! 警告: define/endef 数量不匹配（可能原文件本就不等，或确有损坏）")
    print("!! 若 make 仍报 missing endef 请检查 mt7621.mk；此处不再自杀式中止")
PYEOF
fi

# ===========================================================================
# 9) KST-WF3000A (mt7981b, SPI-NAND, NMBM stock layout) 设备移植注入
#    仅在 immortalwrt 23.05（含 target/linux/mediatek/image/filogic.mk）时生效；
#    18.06 等无此文件则整段跳过，不影响其它分支/其它架构。
#    注入三件套：DTS 文件、filogic.mk 设备定义、board.d/02_network WAN/LAN 分支。
#    （时机：本脚本在 make defconfig 之前运行，设备定义注入后 defconfig 才能识别到它）
# ===========================================================================
FIL="target/linux/mediatek/image/filogic.mk"
if [ -f "$FIL" ] && ! grep -q "define Device/kst_wf3000a" "$FIL"; then
  echo "==> 注入 KST-WF3000A 设备定义到 $FIL"

  # --- 9.1 filogic.mk 设备定义（stock NMBM 布局：整片 ubi + KERNEL_IN_UBI）---
  cat >> "$FIL" <<'MKEOF'

define Device/kst_wf3000a
  DEVICE_VENDOR := KST
  DEVICE_MODEL := WF3000A
  DEVICE_DTS := mt7981-kst-wf3000a
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt7915e kmod-mt7981-firmware mt7981-wo-firmware
  UBINIZE_OPTS := -E 5
  BLOCKSIZE := 128k
  PAGESIZE := 2048
  KERNEL_IN_UBI := 1
  IMAGE_SIZE := 116736k
  IMAGE/sysupgrade.bin := sysupgrade-tar | append-metadata
endef
TARGET_DEVICES += kst_wf3000a
MKEOF

  # --- 9.2 拷贝 DTS 到源码 dts 目录 ---
  DTS_SRC="../scripts/mt7981-kst-wf3000a.dts"
  if [ -f "$DTS_SRC" ]; then
    echo "==> 拷贝 DTS: $DTS_SRC -> target/linux/mediatek/dts/mt7981-kst-wf3000a.dts"
    cp "$DTS_SRC" "target/linux/mediatek/dts/mt7981-kst-wf3000a.dts"
  else
    echo "!! 警告: 未找到 $DTS_SRC，KST-WF3000A 将无法编译（DTS 缺失）"
  fi

  # --- 9.3 注入 board.d/02_network：WAN/LAN 分支（定位真实文件，避免路径硬编码）---
  N2=$(ls target/linux/mediatek/*/base-files/etc/board.d/02_network \
           target/linux/mediatek/base-files/etc/board.d/02_network 2>/dev/null | head -1)
  if [ -n "$N2" ] && ! grep -q "kst,wf3000a)" "$N2"; then
    echo "==> 注入 02_network WAN/LAN 分支到 $N2"
    python3 - "$N2" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
case = ('\n'
        '\tkst,wf3000a)\n'
        '\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3" "wan"\n'
        '\t\t;;\n')
# 关键：接口分配必须写进 mediatek_setup_interfaces()，且在 '*' 默认分支之前。
# 否则会命中 '*' 兜底（lan1 lan2 lan3 lan4）并叠加，导致多出一个不存在的 lan4、且端口重复。
# 先清除任何已存在的 kst 块（避免重复或错插到 macs 函数）。
s = re.sub(r'\n\tkst,wf3000a\)\n(?:\t\t[^\n]*\n)*\t\t;;\n', '\n', s)
fn = s.index('mediatek_setup_interfaces()')
star = s.index('\t*)', fn)
s = s[:star] + case + s[star:]
open(p, "w", encoding="utf-8").write(s)
print("patched 02_network (interfaces case, before '*') for kst,wf3000a")
PYEOF
  else
    echo "==> 02_network 未找到或已含 kst,wf3000a，跳过网络分支注入"
  fi
else
  echo "==> filogic.mk 不存在或已含 kst_wf3000a，跳过 KST 设备注入"
fi

# ===========================================================================
# 10) NanoPi R2S 网络接口绑定修正 (rockchip/armv8)
#     上游默认把 r2s 与 r2c/r4s/r4se 等共享同一行:
#       ucidef_set_interfaces_lan_wan 'eth1' 'eth0'   => lan=eth1, wan=eth0
#     用户要求 WAN 绑 eth1(USB RTL8153), LAN 绑 eth0(板载 RTL8211)，恰好相反。
#     处理：给 r2s 拆出独立 case 分支(只改它)，不动共享行里的 r2c/r4s 等其它设备。
#     仅在 rockchip 平台(02_network 文件存在)时生效，其它架构整段跳过。
# ===========================================================================
R2S_N2="target/linux/rockchip/armv8/base-files/etc/board.d/02_network"
if [ -f "$R2S_N2" ] && ! grep -q "friendlyarm,nanopi-r2s)" "$R2S_N2"; then
  echo "==> 修正 NanoPi R2S 网络绑定: WAN=eth1, LAN=eth0"
  python3 - "$R2S_N2" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
# 1) 从共享 case 列表独占移除 r2s 那一行(匹配到行尾，吃掉整行含续行反斜杠，最鲁棒)
s = re.sub(r"\s*friendlyarm,nanopi-r2s[^\n]*\n", "", s)
# 2) 在 rockchip_setup_interfaces 的 case "$board" in 之后插入 r2s 独立分支
anchor = 'case "$board" in\n'
idx = s.index(anchor) + len(anchor)
ins = ('\tfriendlyarm,nanopi-r2s)\n'
       '\t\tucidef_set_interfaces_lan_wan \'eth0\' \'eth1\'\n'
       '\t\t;;\n')
s = s[:idx] + ins + s[idx:]
open(p, "w", encoding="utf-8").write(s)
print("patched 02_network: r2s lan=eth0 wan=eth1")
PYEOF
elif [ -f "$R2S_N2" ]; then
  echo "==> 02_network 已含 r2s 独立分支，跳过"
else
  echo "==> 非 rockchip 平台，跳过 R2S 网络注入"
fi

# ===========================================================================
# 11) Qihoo 360T6GS (mt7621, NAND, 128MB) 设备移植注入
#     仅在 immortalwrt 23.05（target/linux/ramips/image/mt7621.mk 存在）时生效；
#     18.06 等无此文件则整段跳过，不影响其它分支/架构。
#     注入三件套：DTS、mt7621.mk 设备定义、board.d/02_network 的 interfaces/macs 分支。
#     上游源码：ByteArray0/openwrt-device-expand @9af7bb9（ramips/mt7621，23.05 兼容：
#     DTS 用 nvmem-layout/fixed-layout 风格，已比对 jdcloud_re-sp-01b 确认兼容；
#     mt7915 驱动由 DEVICE_PACKAGES 的 kmod-mt7915-firmware(DEPENDS kmod-mt7915e) 自动带）
# ===========================================================================
RAMIPS_MK="target/linux/ramips/image/mt7621.mk"
if [ -f "$RAMIPS_MK" ] && ! grep -q "define Device/qihoo_360t6gs" "$RAMIPS_MK"; then
  echo "==> 注入 Qihoo 360T6GS 设备定义到 $RAMIPS_MK"

  # --- 11.1 mt7621.mk 设备定义（NAND + uimage-lzma-loader，append-ubi 固件）---
  cat >> "$RAMIPS_MK" <<'MKEOF'

define Device/qihoo_360t6gs
  $(Device/nand)
  $(Device/uimage-lzma-loader)
  DEVICE_VENDOR := Qihoo
  DEVICE_MODEL := 360T6GS
  DEVICE_DTS := mt7621_qihoo_360t6gs
  DEVICE_DTS_DIR := ../dts
  IMAGE_SIZE := 128512k
  IMAGES += firmware.bin
  IMAGE/firmware.bin := append-kernel | pad-to $$(KERNEL_SIZE) | append-ubi | check-size
  DEVICE_PACKAGES += kmod-mt7915-firmware
endef
TARGET_DEVICES += qihoo_360t6gs
MKEOF

  # --- 11.2 拷贝 DTS 到源码 dts 目录 ---
  DTS_SRC="../scripts/mt7621-qihoo-360t6gs.dts"
  if [ -f "$DTS_SRC" ]; then
    echo "==> 拷贝 DTS: $DTS_SRC -> target/linux/ramips/dts/mt7621_qihoo_360t6gs.dts"
    cp "$DTS_SRC" "target/linux/ramips/dts/mt7621_qihoo_360t6gs.dts"
  else
    echo "!! 警告: 未找到 $DTS_SRC，360T6GS 将无法编译（DTS 缺失）"
  fi

  # --- 11.3 注入 board.d/02_network：interfaces + macs 分支 ---
  N2=$(ls target/linux/ramips/*/base-files/etc/board.d/02_network 2>/dev/null | head -1)
  if [ -n "$N2" ] && ! grep -q "qihoo,360t6gs)" "$N2"; then
    echo "==> 注入 02_network 分支到 $N2"
    python3 - "$N2" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()

def ins_at(func):
    # 在 func() 内的第一个 'case $board in' 之后插入（首个匹配优先，避免被 * 默认分支吃掉）
    i = s.index(func + "()")
    ci = s.index('case $board in', i)
    return ci + len('case $board in\n')

iface = ('\tqihoo,360t6gs)\n'
        '\t\tucidef_set_interfaces_lan_wan "lan1 lan2 lan3" "wan"\n'
        '\t\t;;\n')
macs = ('\tqihoo,360t6gs)\n'
        '\t\tlan_mac=$(cat /sys/class/net/eth0/address)\n'
        '\t\twan_mac=$(macaddr_add "$lan_mac" 1)\n'
        '\t\tlabel_mac=$wan_mac\n'
        '\t\t;;\n')
ai = ins_at('ramips_setup_interfaces')
am = ins_at('ramips_setup_macs')
# 先插索引较大的（macs 在后），再插较小的（interfaces），避免位置偏移
if am > ai:
    s = s[:am] + macs + s[am:]
    s = s[:ai] + iface + s[ai:]
else:
    s = s[:ai] + iface + s[ai:]
    s = s[:am] + macs + s[am:]
open(p, "w", encoding="utf-8").write(s)
print("patched 02_network for qihoo,360t6gs (interfaces + macs)")
PYEOF
  else
    echo "==> 02_network 未找到或已含 qihoo,360t6gs，跳过网络分支注入"
  fi
else
  echo "==> mt7621.mk 不存在或已含 qihoo_360t6gs，跳过 360T6GS 设备注入"
fi

# ===========================================================================
# 12) mt7621.mk 语法自检（只读诊断：捕获 "recipe commences before first target" 的两类根因）
#     ① define/endef 未配对；② 续行反斜杠 \ 后紧跟 define/endef/空行(悬挂续行)，
#     会使后续 define 被误判为 recipe。并把 200-260 行打印到日志，便于云端排错。
# ===========================================================================
if [ -f "$RAMIPS_MK" ]; then
  echo "==> [自检] mt7621.mk 语法校验"
  python3 - "$RAMIPS_MK" <<'PYEOF'
import sys, re
p = sys.argv[1]
lines = open(p, encoding="utf-8").read().split("\n")
depth = 0
for i, l in enumerate(lines, 1):
    if re.match(r'^define ', l):
        depth += 1
    elif l == 'endef':
        depth -= 1
        if depth < 0:
            print("!! 第 %d 行 endef 多余（define/endef 不匹配）" % i)
    if l.rstrip().endswith('\\'):
        nxt = lines[i] if i < len(lines) else ''
        if nxt.strip().startswith(('define', 'endef')) or nxt.strip() == '':
            print("!! 第 %d 行悬挂续行反斜杠 -> 下一行 %r" % (i, nxt))
if depth != 0:
    print("!! define/endef 最终未配对: 差 %d" % depth)
else:
    print("OK: define/endef 配对平衡 (%d 对)" % depth)
print("=== mt7621.mk 第 200-260 行（排错用）===")
for i in range(199, min(260, len(lines))):
    print("%d: %r" % (i+1, lines[i]))
PYEOF
fi

# ===========================================================================
# 13) RAISECOM MSG1500 X.00 (ramips/mt7621, MT7615DN) — 5G 发射功率 + 吞吐双修复
#     已用源码(factory 备份 + immortalwrt 23.05 锁定的 mt76 commit 1e336a8)实证根因：
#
#     (a) 999-mt7615-extpa-empty-fallback.patch —— 修复 5G 功率被压到 7dBm
#         factory 中 NIC_CONF_1+1 (0x037) 的 TSSI_5G 位(bit6)=0 → 驱动
#         mt7615_ext_pa_enabled(5G) 返回 true → 走 "external PA" 分支去读
#         MT_EE_EXT_PA_5G_TARGET_POWER(0x0f3)；而该设备 0x0f3 整段为 0(空校准)，
#         5G TX 功率塌到固件地板值 7dBm。补丁在 EXT_PA 校准区为空(全0)时回退到
#         正常目标功率表(0x070=23dBm)，5G 功率恢复到 ~18-19dBm。
#
#     (b) 998-mt7615-disable-precal.patch —— 修复 5G 吞吐卡 ~20Mbps(mt76/issues#880)
#         本机 factory 的 5G 预校准(precal)数据不完整/被改写，驱动套用无效 TX DPD/RX
#         校准 → 5G TX 的 EVM 恶化 → 客户端掉到极低 MCS → 下载(路由器 TX)卡 20Mbps；
#         闭源驱动能到 ~300Mbps 正是因它不走这套坏 precal。补丁清掉 MT_EE_CALDATA_FLASH
#         低5位，强制驱动放弃 flash 预校准、改走运行时在线校准。本机走 flash_eeprom 分支，
#         该补丁必然生效。两补丁协同：999 解决"功率够不够"，998 解决"信号干不干净"。
#
#     补丁文件随仓库发布在 patches/mt76/ ，此处把该目录全部 *.patch 复制到 mt76 包的
#     patches/ 由构建期应用(loop 拷贝，后续加补丁只丢文件即可，无需改本段)。
# ===========================================================================
MSG_PATCH_DIR="$(dirname "$0")/../patches/mt76"
if [ -d "$MSG_PATCH_DIR" ]; then
  MT76_PKG=""
  for d in package/kernel/mt76 package/feeds/*/kernel/mt76 feeds/*/kernel/mt76; do
    [ -f "$d/Makefile" ] && MT76_PKG="$d" && break
  done
  if [ -n "$MT76_PKG" ]; then
    mkdir -p "$MT76_PKG/patches"
    cnt=0
    for p in "$MSG_PATCH_DIR"/*.patch; do
      [ -f "$p" ] || continue
      cp "$p" "$MT76_PKG/patches/"
      cnt=$((cnt+1))
    done
    if [ "$cnt" -gt 0 ]; then
      echo "==> 已注入 MT7615 修复补丁($cnt 个) -> $MT76_PKG/patches/"
    else
      echo "==> $MSG_PATCH_DIR 下无 *.patch，跳过 MT7615 补丁"
    fi
  else
    echo "==> 未找到 mt76 包(请确认 feeds 已安装)，跳过 MT7615 补丁"
  fi
else
  echo "==> 未找到 $MSG_PATCH_DIR，跳过 MT7615 补丁"
fi

# ===========================================================================
# 14) Phicomm K2P 32M (ramips/mt7621, 32MB SPI-NOR) 设备移植注入
#     上游只内置标准 16MB 版 phicomm_k2p（IMAGE_SIZE 15744k），没有 32MB 变体。
#     本段注入：DTS(mt7621_phicomm_k2p_32m.dts) + mt7621.mk 设备定义。
#     分区：u-boot/u-boot-env/factory 保持不变，删掉原厂 permanent_config，
#           firmware 前移到 0x50000 并扩为 0x50000+0x1fb0000（正好到 32MB 末尾）
#           → IMAGE_SIZE := 32448k（= 0x1fb0000 / 1024）。
#           即固件从 factory 之后紧接开始，与 Breed/常见 MT7621 布局一致。
#     网络：compatible "phicomm,k2p-32m" 无需单列 02_network 分支，
#           原生兜底 *) = ucidef_set_interfaces_lan_wan "lan1 lan2 lan3 lan4" "wan"，
#           与 K2P 的 4×LAN + 1×WAN 完全一致（已核实 23.05 的 02_network）。
#     仅在 immortalwrt（mt7621.mk 存在）时生效；18.06 等无此文件则整段跳过。
# ===========================================================================
if [ -f "$RAMIPS_MK" ] && ! grep -q "define Device/phicomm_k2p-32m" "$RAMIPS_MK"; then
  echo "==> 注入 Phicomm K2P 32M 设备定义到 $RAMIPS_MK"

  # --- 14.1 mt7621.mk 设备定义（SPI-NOR + dsa-migration；无线仅 MT7615）---
  cat >> "$RAMIPS_MK" <<'MKEOF'

define Device/phicomm_k2p-32m
  $(Device/dsa-migration)
  IMAGE_SIZE := 32448k
  DEVICE_VENDOR := Phicomm
  DEVICE_MODEL := K2P 32M
  DEVICE_ALT0_VENDOR := Phicomm
  DEVICE_ALT0_MODEL := KE 2P
  DEVICE_DTS := mt7621_phicomm_k2p_32m
  DEVICE_DTS_DIR := ../dts
  SUPPORTED_DEVICES += k2p-32m
  DEVICE_PACKAGES := kmod-mt7615-firmware -uboot-envtools
endef
TARGET_DEVICES += phicomm_k2p-32m
MKEOF

  # --- 14.2 拷贝 DTS 到源码 dts 目录 ---
  K2P_DTS_SRC="../scripts/mt7621_phicomm_k2p_32m.dts"
  if [ -f "$K2P_DTS_SRC" ]; then
    echo "==> 拷贝 DTS: $K2P_DTS_SRC -> target/linux/ramips/dts/mt7621_phicomm_k2p_32m.dts"
    cp "$K2P_DTS_SRC" "target/linux/ramips/dts/mt7621_phicomm_k2p_32m.dts"
  else
    echo "!! 警告: 未找到 $K2P_DTS_SRC，K2P 32M 将无法编译（DTS 缺失）"
  fi
else
  echo "==> mt7621.mk 不存在或已含 phicomm_k2p-32m，跳过 K2P 32M 设备注入"
fi

# ===========================================================================
# 15) Phicomm K2 32M (ramips/mt7620, MT7620A, 32MB SPI-NOR) 设备移植注入
#     上游只内置 8MB 版 phicomm_k2-v22.4（IMAGE_SIZE 7872k）/ phicomm_k2-v22.5（7552k）
#     与 phicomm_psg1218b，没有 32MB 变体。
#     本段注入三件套：
#       ① DTS  mt7620a_phicomm_k2_32m.dts（由 k2x.dtsi 派生，仅改 firmware 分区）
#          注意：23.05 与 18.06-k5.4 的 mt7620a.dtsi 不同 —— 18.06 只有 pa_pins、
#          没有 pa_gpio_pins，故准备了两个版本，脚本按 dtsi 里是否存在
#          pa_gpio_pins 自动挑选（见 15.2），两分支共用同一目标 DTS 名。
#       ② mt7620.mk 设备定义（SOC=mt7620a，显式 DEVICE_DTS 避免默认名带连字符）
#       ③ board.d/02_network 的 interfaces + macs 分支
#     分区：u-boot/u-boot-env/factory 不变，firmware 起始保持 0x50000
#           （与原厂 v22.4 一致，不设 permanent_config），
#           大小 0x50000+0x1fb0000（正好到 32MB 末尾）→ IMAGE_SIZE := 32448k。
#     重要：MT7620 是 swconfig 平台，不像 mt7621(DSA) 有 *) 兜底分支，
#           若不加 02_network 分支，开机后 LAN/WAN 全空、只能靠串口救。
#     仅在 immortalwrt（mt7620.mk 存在）时生效；openwrt-23.05 与 openwrt-18.06-k5.4
#     两者均内置该文件，故两个分支都会执行本站注入。
# ===========================================================================
MT7620_MK="target/linux/ramips/image/mt7620.mk"
if [ -f "$MT7620_MK" ] && ! grep -q "define Device/phicomm_k2-32m" "$MT7620_MK"; then
  echo "==> 注入 Phicomm K2 32M 设备定义到 $MT7620_MK"

  # --- 15.1 mt7620.mk 设备定义（SPI-NOR；无线 MT7612E 由 kmod-mt76x2 带）---
  cat >> "$MT7620_MK" <<'MKEOF'

define Device/phicomm_k2-32m
  SOC := mt7620a
  IMAGE_SIZE := 32448k
  DEVICE_VENDOR := Phicomm
  DEVICE_MODEL := K2
  DEVICE_VARIANT := 32M
  DEVICE_DTS := mt7620a_phicomm_k2_32m
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := kmod-mt76x2
  SUPPORTED_DEVICES += k2-32m
endef
TARGET_DEVICES += phicomm_k2-32m
MKEOF

  # --- 15.2 拷贝 DTS 到源码 dts 目录（按分支 dtsi 自动选版本）---
  #     23.05 的 mt7620a.dtsi 同时定义 pa_pins 与 pa_gpio_pins，DTS 可写双 pinctrl 状态；
  #     18.06-k5.4 只有 pa_pins，引用 pa_gpio_pins 会 dtc 报 label 找不到 → 整机编不出。
  #     故以目标 dtsi 是否含 pa_gpio_pins 为判据选择 DTS 源文件，目标文件名保持一致。
  if grep -q 'pa_gpio_pins' target/linux/ramips/dts/mt7620a.dtsi 2>/dev/null; then
    K2_DTS_SRC="../scripts/mt7620a_phicomm_k2_32m.dts"
    echo "==> 检测到 pa_gpio_pins（23.05 系），使用标准版 DTS"
  else
    K2_DTS_SRC="../scripts/mt7620a_phicomm_k2_32m_1806.dts"
    echo "==> 未检测到 pa_gpio_pins（18.06 系），使用仅 pa_pins 版 DTS"
  fi
  if [ -f "$K2_DTS_SRC" ]; then
    echo "==> 拷贝 DTS: $K2_DTS_SRC -> target/linux/ramips/dts/mt7620a_phicomm_k2_32m.dts"
    cp "$K2_DTS_SRC" "target/linux/ramips/dts/mt7620a_phicomm_k2_32m.dts"
  else
    echo "!! 警告: 未找到 $K2_DTS_SRC，K2 32M 将无法编译（DTS 缺失）"
  fi

  # --- 15.3 注入 board.d/02_network：interfaces + macs 分支 ---
  #     锚点：phicomm,k2-v22.4|\ 在 interfaces 与 macs 两个 case 分组里各出现一次，
  #     在它前面插入 phicomm,k2-32m|\ 即可复用 v22.4 的网口(0:lan:4..3:lan:1,4:wan,6@eth0)
  #     与 MAC 取址(factory 0x2e) 规则。
  K2_N2="target/linux/ramips/mt7620/base-files/etc/board.d/02_network"
  if [ -f "$K2_N2" ] && ! grep -q "phicomm,k2-32m" "$K2_N2"; then
    echo "==> 注入 02_network 分支到 $K2_N2"
    python3 - "$K2_N2" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
needle = "\tphicomm,k2-v22.4|\\\n"
ins = "\tphicomm,k2-32m|\\\n"
n = s.count(needle)
if n == 0:
    print("!! WARNING: 未找到 phicomm,k2-v22.4 锚点，02_network 未修改（网口/MAC 会缺分支）")
else:
    s = s.replace(needle, ins + needle)
    open(p, "w", encoding="utf-8").write(s)
    print("patched 02_network: phicomm,k2-32m inserted into %d case group(s)" % n)
PYEOF
  else
    echo "==> 02_network 未找到或已含 phicomm,k2-32m，跳过网络分支注入"
  fi
else
  echo "==> mt7620.mk 不存在或已含 phicomm_k2-32m，跳过 K2 32M 设备注入"
fi

# ===========================================================================
# 16) 18.06 系补 iptables-mod-socket 兼容元包（消除 luci-app-ssr-plus 的假警告）
#     现象：18.06-k5.4 固件启动 ssr-plus 后日志报
#           "警告：iptables 透明代理缺失基础依赖 iptables-mod-socket！"
#     根因（已核实，非真缺功能，是**包名代差**）：
#       helloworld master 的 luci-app-ssr-plus/root/etc/init.d/shadowsocksr 用
#       dep_list="iptables-mod-tproxy iptables-mod-socket iptables-mod-iprange
#                  iptables-mod-conntrack-extra kmod-ipt-nat"
#       逐个检查 /usr/lib/opkg/info/<pkg>.control 是否存在，缺一即告警（纯静态检测）。
#       而 18.06/18.06-k5.4 的 iptables 包**根本没有** iptables-mod-socket：
#         · package/network/utils/iptables/Makefile 无 Package/iptables-mod-socket，
#           socket match（libxt_socket.so）由 BuildPlugin(iptables-mod-tproxy,
#           $(IPT_TPROXY-m)) 一并拷进 iptables-mod-tproxy；
#         · include/netfilter.mk 的 IPT_TPROXY 组里就是 nf_add(...XT_MATCH_SOCKET,
#           $(P_XT)xt_socket)，即 xt_socket.ko / nf_socket_ipv4/ipv6 都在 kmod-ipt-tproxy；
#         · 23.05 起才拆成独立的 iptables-mod-socket + kmod-ipt-socket。
#       → 功能无恙，只是 18.06 把 socket match 合并进了 tproxy 包。
#     做法：补一个元包 iptables-mod-socket，DEPENDS:=+iptables-mod-tproxy，
#       安装后生成 /usr/lib/opkg/info/iptables-mod-socket.control，检测即通过；
#       **不复制 libxt_socket.so**，避免与 iptables-mod-tproxy 争抢同一文件
#       触发 opkg 的 check_data_file_clashes。
#       ⚠ install 段**不能留空**：include/package-ipkg.mk 用
#         `ifdef Package/<name>/install` 判定，空定义等价于未定义 →
#         打印 "WARNING: skipping <pkg> -- package has no install section"
#         且该包不会进镜像（ipk 照样编得出来，表现为「编译成功但固件里没这个包」）。
#       故 install 段必须真装至少一个文件（这里放一个无害的说明文件）。
#     判据：仅当主源 iptables Makefile 里没有 Package/iptables-mod-socket（=18.06 系）
#           时注入；23.05/master 自带真包，自动跳过，不产生重名冲突。
# ===========================================================================
IPT_MK="package/network/utils/iptables/Makefile"
if [ -f "$IPT_MK" ] && ! grep -q "Package/iptables-mod-socket" "$IPT_MK"; then
  COMPAT_DIR="package/network/utils/iptables-mod-socket-compat"
  if [ ! -f "$COMPAT_DIR/Makefile" ] || ! grep -q 'INSTALL_DIR' "$COMPAT_DIR/Makefile"; then
    echo "==> 注入 iptables-mod-socket 兼容元包（18.06 系：socket match 实际在 iptables-mod-tproxy 内）"
    mkdir -p "$COMPAT_DIR"
    cat > "$COMPAT_DIR/Makefile" <<'MKEOF'
# 兼容元包：18.06 系源码没有独立的 iptables-mod-socket 包。
# 真正的 socket match（libxt_socket.so）与内核 xt_socket.ko / nf_socket_ipv4/ipv6
# 都在 iptables-mod-tproxy / kmod-ipt-tproxy 里，本包只提供包名，不安装任何文件。
include $(TOPDIR)/rules.mk

PKG_NAME:=iptables-mod-socket
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/iptables-mod-socket
  SECTION:=net
  CATEGORY:=Network
  SUBMENU:=Firewall
  TITLE:=Socket match iptables extensions (compat meta package)
  DEPENDS:=+iptables-mod-tproxy
  PKGARCH:=all
endef

define Package/iptables-mod-socket/description
Compatibility meta package for 18.06 based sources. The iptables socket
match (libxt_socket.so) and the xt_socket kernel modules are shipped
inside iptables-mod-tproxy / kmod-ipt-tproxy on this branch.
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/iptables-mod-socket/install
	$(INSTALL_DIR) $(1)/usr/share/iptables-mod-socket
	echo "compat meta package: on 18.06 the socket match (libxt_socket.so) and" \
		"xt_socket/nf_socket_* kernel modules are shipped by iptables-mod-tproxy" \
		"and kmod-ipt-tproxy." \
		> $(1)/usr/share/iptables-mod-socket/README
endef

$(eval $(call BuildPackage,iptables-mod-socket))
MKEOF
  else
    echo "==> iptables-mod-socket 兼容元包已存在，跳过"
  fi
else
  echo "==> 主源自带 iptables-mod-socket（23.05 系）或 iptables 目录缺失，跳过兼容元包注入"
fi

# 16) EZVIZ CS-W3-WD1200G (W3) —— ipq40xx / IPQ4018 + 128MB DDR3，32MB SPI-NOR 改造
#
#     背景：这台机器原厂只有 16MB SPI-NOR（Macronix MX25L12805D），
#           装不下 ssr-plus 依赖的 xray-core（精简版 UPX 后仍需 5.8MB，
#           而 16MB 布局下 overlay 只剩约 3MB），故硬件换 32MB 芯片。
#           换片后必须让 Linux 侧分区表同步扩容，否则多出来的 16MB 用不上。
#
#     本段做三件事（全部幂等，可重复执行）：
#       ① 改 DTS：firmware 分区从 0x180000+0xE80000(14.5MiB) 扩到 0x180000+0x1E80000(30.5MiB)
#          0x180000 + 0x1E80000 = 0x2000000 = 32MiB，正好吃掉芯片末尾
#       ② 改 generic.mk：IMAGE_SIZE 14848k -> 31232k
#          （0x1E80000 = 31981568 B = 31232 KiB，与 firmware 分区严格对齐；
#            不放开这个限制，即使 DTS 扩容了，编译期 check-size 仍会卡在 14.5MB）
#       ③ 注入 32MB zram swap（不用 zram-swap 包，因为它按 RAM/2=64MB 建盘，
#          对 128MB 机器反而挤占物理内存）
#
#     ⚠️ 分区前段（SBL1/MIBIB/QSEE/CDT/DDRPARAMS/APPSBLENV/APPSBL/ART）一律不动：
#        0x00000000 ~ 0x00180000 共 1.5MB，含 U-Boot、DDR 参数、MAC 地址和 Wi-Fi 校准
#        （ART 分区里的 precal_art_1000 / precal_art_5000 是 ath10k 的预校准数据）。
#        换芯片时必须把原片这 1.5MB 原样烧到新片同位置，否则砖且 Wi-Fi 无校准。
#
#     ⚠️ 设备名不能改：BOARD_NAME 决定 ipq-wifi BDF 包名，DTS 里
#        qcom,ath10k-calibration-variant = "ezviz-cs-w3-wd1200g-eup" 决定驱动找哪个
#        board-*-ezviz_cs-w3-wd1200g-eup 校准文件。一旦改设备名，BDF 找不到，Wi-Fi 退化。
#
#     ⚠️ Wi-Fi 驱动：上游 generic.mk 的 DEVICE_PACKAGES 已写死
#        `-kmod-ath10k-ct kmod-ath10k-ct-smallbuffers`，即 smallbuffers 变体是默认行为，
#        本段无需再改（config 里显式固化一次，防 defconfig 翻回 regular buffer）。
IPQ40XX_DTS=$(ls target/linux/ipq40xx/files*/arch/arm/boot/dts/qcom-ipq4018-cs-w3-wd1200g-eup.dts 2>/dev/null | head -1)
IPQ40XX_GMK="target/linux/ipq40xx/image/generic.mk"
if [ -n "$IPQ40XX_DTS" ] && [ -f "$IPQ40XX_GMK" ]; then
  echo "==> [16] EZVIZ W3 32MB 闪存布局注入（DTS: $IPQ40XX_DTS）"
  python3 - "$IPQ40XX_DTS" "$IPQ40XX_GMK" <<'PYEOF'
import re, sys

dts_path, gmk_path = sys.argv[1], sys.argv[2]
FLASH_BYTES = 0x02000000          # 32MB

# ---- (1) DTS: firmware 分区扩容 ----
s = open(dts_path, encoding="utf-8").read()
pat = re.compile(
    r'(label\s*=\s*"firmware";\s*\n\s*reg\s*=\s*<)(0x[0-9a-fA-F]+)(\s+)(0x[0-9a-fA-F]+)(>;)'
)
m = pat.search(s)
if not m:
    print("  !! DTS: 未找到 firmware 分区的 label+reg 组合，放弃（请人工检查）")
    sys.exit(1)

start = int(m.group(2), 16)
size_old = int(m.group(4), 16)
size_new = FLASH_BYTES - start

if size_old == size_new:
    print("  DTS: firmware 已是目标布局（%.1fMiB），跳过" % (size_new / 1048576.0))
else:
    new_reg = "%s0x%08x%s0x%08x%s" % (
        m.group(1), start, m.group(3), size_new, m.group(5)
    )
    s = s[:m.start()] + new_reg + s[m.end():]
    # 节点名 partitionN@xxx 只是标签、不参与解析，顺手按真实起始地址修正，便于阅读
    s = re.sub(
        r'partition(\d+)@[0-9a-fA-F]+(\s*\{\s*\n\s*compatible\s*=\s*"denx,fit";)',
        lambda mm: "partition%s@%x%s" % (mm.group(1), start, mm.group(2)),
        s)
    open(dts_path, "w", encoding="utf-8").write(s)
    print("  DTS: firmware 0x%08x+0x%08x (%.1fMB) -> +0x%08x (%.1fMB)，止于 0x%08x"
          % (start, size_old, size_old / 1048576.0, size_new, size_new / 1048576.0,
             start + size_new))

# ---- (2) generic.mk: IMAGE_SIZE ----
DEV = "ezviz_cs-w3-wd1200g-eup"
OLD_ISZ, NEW_ISZ = "IMAGE_SIZE := 14848k", "IMAGE_SIZE := 31232k"
lines = open(gmk_path, encoding="utf-8").read().split("\n")
b_start = None
for i, ln in enumerate(lines):
    if ln.startswith("define Device/" + DEV):
        b_start = i
        break
if b_start is None:
    print("  !! generic.mk: 未找到 define Device/%s 块" % DEV)
else:
    b_end = None
    for j in range(b_start, len(lines)):
        if lines[j].rstrip() == "endef":
            b_end = j
            break
    if b_end is None:
        print("  !! generic.mk: %s 块缺少 endef" % DEV)
    else:
        seg = "\n".join(lines[b_start:b_end])
        if NEW_ISZ in seg:
            print("  generic.mk: IMAGE_SIZE 已是 31232k，跳过")
        elif OLD_ISZ in seg:
            lines[b_start:b_end] = seg.replace(OLD_ISZ, NEW_ISZ).split("\n")
            open(gmk_path, "w", encoding="utf-8").write("\n".join(lines))
            print("  generic.mk: %s  IMAGE_SIZE 14848k -> 31232k（14.5MiB -> 30.5MiB）" % DEV)
        else:
            print("  !! generic.mk: %s 块内未找到 IMAGE_SIZE := 14848k（上游可能已变更）" % DEV)

# ---- 自检：分区总长必须正好等于芯片容量 ----
end_max = 0
for ln in open(dts_path, encoding="utf-8").read().split("\n"):
    mm = re.search(r'reg\s*=\s*<\s*(0x[0-9a-fA-F]+)\s+(0x[0-9a-fA-F]+)\s*>;', ln)
    if mm:
        end_max = max(end_max, int(mm.group(1), 16) + int(mm.group(2), 16))
print("  自检: 全部分区末端 = 0x%08x (%dMB)，芯片容量 = 0x%08x (%dMB)  %s"
      % (end_max, end_max // 0x100000, FLASH_BYTES, FLASH_BYTES // 0x100000,
         "OK" if end_max == FLASH_BYTES else "!! 不匹配，请检查分区表"))
PYEOF

  # ---- (3) 32MB zram swap（自定义 init，绕开 zram-swap 包的 RAM/2 逻辑）----
  # 注意：diy-part2.sh 在 workflow 里于 `cp .config` 之前执行，此时拿不到矩阵中的
  # 机型名，因此本脚本会随 files/ 打包进【所有机型】的固件。没有 kmod-zram 的机型
  # modprobe 失败即 return 0，不建盘、不占内存，实测无副作用；
  # 只有本 config 选了 CONFIG_PACKAGE_kmod-zram=y 的机型（即本机型）才真正生效。
  mkdir -p files/etc/init.d files/etc/uci-defaults
  cat > files/etc/init.d/zramswap <<'ZRAMEOF'
#!/bin/sh /etc/rc.common
# 32MB zram swap —— 128MB 内存机型的应急缓冲
# 由 r6220 云编译 diy-part2.sh 第 16 段注入。
# 若系统中已有 zram 在用（例如同时装了 zram-swap 包），本脚本检测后直接退出。
START=11

start() {
	[ -e /sys/block/zram0/disksize ] || modprobe zram 2>/dev/null || return 0
	# disksize 非 0 说明已有盘在用，不重复建
	[ "$(cat /sys/block/zram0/disksize 2>/dev/null)" = "0" ] || return 0
	echo 33554432 > /sys/block/zram0/disksize 2>/dev/null || return 0
	mkswap /dev/zram0 >/dev/null 2>&1
	swapon -p 10 /dev/zram0 2>/dev/null
}

stop() {
	swapoff /dev/zram0 2>/dev/null
	echo 1 > /sys/block/zram0/reset 2>/dev/null
}
ZRAMEOF
  chmod +x files/etc/init.d/zramswap
  # rc.d 的启动链接交给 OpenWrt 自己的 `enable` 生成：
  # 直接在构建机上 ln -s 会因宿主平台不同而失败（Windows/无符号链接权限报
  # "Operation not permitted"，且会留下 0 字节垃圾文件）。
  # uci-defaults 脚本在固件首次启动时执行一次后自动删除，跨平台且符合 OpenWrt 规范。
  cat > files/etc/uci-defaults/99-enable-zramswap <<'UCIEOF'
#!/bin/sh
/etc/init.d/zramswap enable
exit 0
UCIEOF
  chmod +x files/etc/uci-defaults/99-enable-zramswap
  echo "  已注入 /etc/init.d/zramswap（32MB，swap 优先级 10）+ uci-defaults 自动 enable"
else
  echo "==> [16] 未找到 ipq40xx 的 ezviz DTS 或 generic.mk，跳过 W3 32MB 注入"
fi

# ---------------------------------------------------------------------------
# [17] A3004NS-dual：启用 MT7621 PPE 硬件 offload（nf_flow_table 硬件卸载路径）
#   只对本机型生效：TARGET_CONFIG 由 workflow 的 DIY-P2 步骤注入矩阵机型名，
#   为空或不含 a3004ns 时整段跳过，绝不污染其它机型（其它机型可能没有
#   xt_FLOWOFFLOAD，硬写 flow_offloading 会让 fw3 启动时报 target 不存在）。
#
#   内核侧前提（config 已保证）：
#     kmod-ipt-offload=y → 提供 xt_FLOWOFFLOAD（含 --hw 参数）
#     kmod-nf-flow=y    → KCONFIG 同时置位 CONFIG_NF_FLOW_TABLE 与
#                         CONFIG_NF_FLOW_TABLE_HW，缺 NF_FLOW_TABLE_HW 时
#                         fw3 的 --hw 会退化/报错，硬件卸载不成立
#   驱动侧前提（本分支默认即有）：
#     CONFIG_NET_RALINK_OFFLOAD=y（Kconfig 里 def_bool NET_RALINK_SOC +
#     depends on NET_RALINK_MT7621），实现见 ralink/mtk_offload.c
#
#   下发侧落两处，互为备份：
#     a) files/etc/uci-defaults/99-a3004ns-hw-offload —— 首次启动写 uci，
#        sysupgrade 保留旧 /etc/config 时也能补齐（脚本执行后自动删除）
#     b) 直接补丁 firewall 包的默认 firewall.config —— 首次刷入即带好选项，
#        不依赖 uci-defaults 的执行时机
# ---------------------------------------------------------------------------
if echo "${TARGET_CONFIG:-}" | grep -qiE 'a3004ns'; then
  echo "==> [17] 注入硬件 offload（$TARGET_CONFIG）：fw3 flow_offloading_hw=1"

  FW_CONF="package/network/config/firewall/files/firewall.config"
  if [ -f "$FW_CONF" ]; then
    python3 - "$FW_CONF" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
if "flow_offloading" in s:
    print("  firewall.config 已含 flow_offloading，跳过补丁")
else:
    lines = s.split("\n")
    out, done = [], False
    for ln in lines:
        out.append(ln)
        if not done and ln.strip() == "config defaults":
            out.append("\toption flow_offloading\t\t1")
            out.append("\toption flow_offloading_hw\t1")
            done = True
    if not done:
        print("  !! 未找到 'config defaults' 段，firewall.config 未修改")
        sys.exit(0)
    open(p, "w", encoding="utf-8").write("\n".join(out))
    print("  patched %s: defaults 段加入 flow_offloading / flow_offloading_hw" % p)
PYEOF
  else
    echo "  (skip firewall.config 补丁：未找到 $FW_CONF，可能不是 firewall3 分支)"
  fi

  mkdir -p files/etc/uci-defaults
  cat > files/etc/uci-defaults/99-a3004ns-hw-offload <<'UCIEOF'
#!/bin/sh
# A3004NS-dual 首次启动：启用 MT7621 PPE 硬件 offload
# 由 r6220 云编译 diy-part2.sh 第 17 段注入，执行一次后自动删除。
# 说明：flow_offloading 是 flow_offloading_hw 的前置开关，两个都必须写。
# 校验：只有内核真的带 nf_flow_table_hw（内建或 .ko）才启用，
#       否则 fw3 下发 `-j FLOWOFFLOAD --hw` 会失败并让防火墙启动报错。
#       判据用 modules.builtin / modules.dep —— 比 /sys/module 可靠
#       （内建模块不一定有 /sys/module 项，误判会导致功能静默不生效）。
_KV=$(uname -r)
if ! grep -q "nf_flow_table_hw" "/lib/modules/$_KV/modules.builtin" 2>/dev/null && \
   ! grep -q "nf_flow_table_hw" "/lib/modules/$_KV/modules.dep" 2>/dev/null; then
	logger -t hw-offload "内核未带 nf_flow_table_hw，跳过硬件 offload（不影响正常上网）"
	exit 0
fi
uci -q get firewall.@defaults[0] >/dev/null 2>&1 || exit 0
uci -q set firewall.@defaults[0].flow_offloading='1'
uci -q set firewall.@defaults[0].flow_offloading_hw='1'
uci -q commit firewall
logger -t hw-offload "已启用 flow_offloading + flow_offloading_hw"
exit 0
UCIEOF
  chmod +x files/etc/uci-defaults/99-a3004ns-hw-offload
  echo "  已注入 /etc/uci-defaults/99-a3004ns-hw-offload（首次启动写入 uci 并 commit）"
else
  echo "==> [17] 非 a3004ns 机型（TARGET_CONFIG='${TARGET_CONFIG:-}'），跳过硬件 offload 注入"
fi
