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
