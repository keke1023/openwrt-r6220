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

# 5) DW33D 纯 SPI NOR 启动支持
#    immortalwrt 官方 dw33d 只生成 NAND ubi 固件（IMAGE_SIZE=96MB），无 SPI-only 镜像。
#    注入 SPI NOR 镜像目标：写到 SPI 的 oem-firmware 分区（DTS 中 0x50000 起，15.625MB）。
#    uboot 需配置为从 SPI 启动。生成的镜像在 bin/targets/ath79/nand/ 下：
#      *-factory-nor.bin / *-sysupgrade-nor.bin
NAND_MK="target/linux/ath79/image/nand.mk"
if [ -f "$NAND_MK" ] && grep -q "define Device/domywifi_dw33d" "$NAND_MK"; then
  if ! grep -q "factory-nor.bin" "$NAND_MK"; then
    echo "==> 注入 DW33D SPI NOR 镜像目标 (factory-nor.bin / sysupgrade-nor.bin)"
    python3 - "$NAND_MK" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
m = re.search(r"(define Device/domywifi_dw33d\n.*?)(\nendef)", s, re.S)
if not m:
    print("!! dw33d block not found, skip")
    sys.exit(0)
block = m.group(1)
if "factory-nor.bin" in block:
    print("already patched, skip")
    sys.exit(0)
add = ("\n"
       "  IMAGES += factory-nor.bin sysupgrade-nor.bin\n"
       "  IMAGE/factory-nor.bin := append-kernel | pad-to 4096k | append-rootfs | pad-rootfs | check-size 15360k\n"
       "  IMAGE/sysupgrade-nor.bin := append-kernel | pad-to 4096k | append-rootfs | pad-rootfs | check-size 15360k | append-metadata\n")
s = s[:m.end(1)] + add + s[m.end(1):]
# 剔除 DW33D 设备默认的 USB 包（用户不需要 USB，纯 SPI 精简版）
s = s.replace("kmod-usb2 kmod-usb-storage kmod-usb-ledtrig-usbport \\\n\t", "")
s = s.replace("kmod-usb2 kmod-usb-storage kmod-usb-ledtrig-usbport", "")
open(p, "w", encoding="utf-8").write(s)
print("patched nand.mk for DW33D SPI")
PYEOF
  fi
fi

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
    out = []
    for j in range(start, end):
        ln = lines[j]
        for pkg in pkgs:
            ln = remove_pkg(ln, pkg)
        # 丢弃被清空/变空白的行（含孤立续行、纯空白、空 DEVICE_PACKAGES 赋值）
        if ln.strip() in ("", "\t", "\\", "DEVICE_PACKAGES", "DEVICE_PACKAGES :="):
            continue
        out.append(ln)
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
