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
