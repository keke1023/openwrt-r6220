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

# 6) D-Link DIR-882 A1 去除 USB（用户不需要 USB，纯 SPI 16MB 精简版）
#    dir-882-a1 继承 dlink_dir-8xx-a1 父模板（仅无线），子定义里 DEVICE_PACKAGES += kmod-usb3
#    kmod-usb-ledtrig-usbport。需从子定义里剔除这两行（设备 profile 写死，.config 删不掉）。
MT7621_MK="target/linux/ramips/image/mt7621.mk"
if [ -f "$MT7621_MK" ] && grep -q "define Device/dlink_dir-882-a1" "$MT7621_MK"; then
  if grep -q "kmod-usb3 kmod-usb-ledtrig-usbport" "$MT7621_MK"; then
    echo "==> 剔除 DIR-882 A1 默认 USB 包 (kmod-usb3 / kmod-usb-ledtrig-usbport)"
    # 删掉 dir-882-a1 子定义里追加 USB 的那一行（保持设备 DEVICE 符号不变，仅去 USB 包）
    sed -i '/define Device\/dlink_dir-882-a1/,/endef/{/DEVICE_PACKAGES += kmod-usb3 kmod-usb-ledtrig-usbport/d}' "$MT7621_MK"
  fi
fi

# 7) 友华 WR1200JS 去除 USB（用户不需要 USB，纯 SPI 16MB 精简版）
#    youhua_wr1200js 的 DEVICE_PACKAGES := kmod-mt7603 kmod-mt76x2 kmod-usb3 \
#        kmod-usb-ledtrig-usbport（单行续行格式，不能整行删，否则 mt7603/mt76x2 也丢）。
#    用 python 精准剔除 USB 包字样，保留无线包与续行结构。
MT7621_MK="target/linux/ramips/image/mt7621.mk"
if [ -f "$MT7621_MK" ] && grep -q "define Device/youhua_wr1200js" "$MT7621_MK"; then
  if grep -q "kmod-usb3" "$MT7621_MK"; then
    echo "==> 剔除 WR1200JS 默认 USB 包 (kmod-usb3 / kmod-usb-ledtrig-usbport，保留 mt7603/mt76x2)"
    python3 - "$MT7621_MK" <<'PYEOF'
import sys, re
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
# 把 " kmod-usb3 \" 从 DEVICE_PACKAGES 行里剔掉（保留前面的无线包与续行符）
s = s.replace(" kmod-usb3 \\\n\t", "\n\t")
# 删掉独立的续行 USB 包行（kmod-usb-ledtrig-usbport）
s = re.sub(r"\n\tkmod-usb-ledtrig-usbport\n", "\n", s)
open(p, "w", encoding="utf-8").write(s)
print("patched mt7621.mk for WR1200JS USB removal")
PYEOF
  fi
fi

# 8) ipTIME A3004NS-Dual 去除 USB + 无线驱动（用户要求：纯有线路由，不要无线/USB）
#    iptime_a3004ns-dual 的 DEVICE_PACKAGES := kmod-usb3 kmod-mt76x2 kmod-usb-ledtrig-usbport
#    （单行格式，无续行）。该设备去 USB+无线后无任何额外包，直接清空 DEVICE_PACKAGES 行。
MT7621_MK="target/linux/ramips/image/mt7621.mk"
if [ -f "$MT7621_MK" ] && grep -q "define Device/iptime_a3004ns-dual" "$MT7621_MK"; then
  if grep -q "kmod-mt76x2" "$MT7621_MK"; then
    echo "==> 剔除 A3004NS-Dual 默认 USB + 无线包 (kmod-usb3 / kmod-mt76x2 / kmod-usb-ledtrig-usbport)"
    # 清空该设备的 DEVICE_PACKAGES（保留设备符号与 uimage-lzma-loader）
    sed -i '/define Device\/iptime_a3004ns-dual/,/endef/{/DEVICE_PACKAGES := kmod-usb3 kmod-mt76x2 kmod-usb-ledtrig-usbport/d}' "$MT7621_MK"
  fi
fi
