#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ipq40xx 强制包瘦身（专供 EZVIZ CS-W3-WD1200G 原厂 16MB 那台）

背景
----
18.06-k5.4 的 target/linux/ipq40xx/Makefile 用 **target 级** DEFAULT_PACKAGES
把下面这些硬塞进每一台 ipq40xx 设备的镜像。它们不写在设备块的 DEVICE_PACKAGES
里，所以 .config 里的 CONFIG_PACKAGE_xxx=n **删不掉** —— defconfig 之后依然会
被并入镜像包列表，组装时要么报「package 缺失」，要么白占几百 KB：

    FEATURES:=squashfs fpu ramdisk nand
    DEFAULT_PACKAGES += kmod-usb-dwc3-qcom kmod-leds-gpio ... \
                        kmod-ath10k-ct wpad-openssl uboot-envtools \
                        kmod-usb3 kmod-usb-dwc3 ath10k-firmware-qca4019-ct \
                        ath10k-board-qca4019 autocore-arm e2fsprogs

本机实际情况：
  * 只有一个 DC 供电口，**没有 USB 口** —— usb3 / dwc3 / dwc3-qcom 纯属白给
  * **SPI NOR**，没有 NAND、没有 UBI 卷 —— nand 特性只会拉进 ubi-utils
  * 家里只用 WPA2-PSK —— wpad-basic 比 wpad-openssl 省约 100KB
  * e2fsprogs 是给 ext4 用的，本机不挂任何外置存储

因此本脚本做三件事：
  1) FEATURES 去掉 nand（18.06 这行是 `:=` 不是 `+=`，两种都认）
  2) DEFAULT_PACKAGES 去掉 kmod-usb-dwc3-qcom / kmod-usb3 / kmod-usb-dwc3 / e2fsprogs
  3) wpad-openssl -> wpad-basic

**保留 kmod-ath10k-ct**：本设备在 generic.mk 里写的是
`-kmod-ath10k-ct kmod-ath10k-ct-smallbuffers`，即上游自己会把它摘掉并换成
smallbuffers 变体，属既定行为，不动它。

用法（在 openwrt 源码根目录下）：
    python3 ../scripts/patch-ipq40xx-slim.py
或显式指定：
    python3 ../scripts/patch-ipq40xx-slim.py target/linux/ipq40xx/Makefile
"""

import re
import sys

DEFAULT_MK = "target/linux/ipq40xx/Makefile"

# 要剔除的 token（按整词匹配，不会误伤 kmod-usb3-foo 这类）
DROP_TOKENS = [
    "kmod-usb-dwc3-qcom",
    "kmod-usb3",
    "kmod-usb-dwc3",
    "e2fsprogs",
]

# token 替换
SWAPS = [
    ("wpad-openssl", "wpad-basic"),
]


def patch_features(text):
    """把 FEATURES 行里的 nand 去掉。兼容 := / += / = 三种写法。"""
    pat = re.compile(r"^(FEATURES(?::|\+)?=[ \t]*)(.*)$", re.M)

    def repl(m):
        toks = m.group(2).split()
        kept = [t for t in toks if t != "nand"]
        if len(kept) == len(toks):
            return m.group(0)
        return m.group(1) + " ".join(kept)

    return pat.sub(repl, text, count=1)


def patch_default_packages(text):
    """去掉 DEFAULT_PACKAGES 块里的冗余包。

    逐行处理 + 续行感知：某一行被删空就整行丢弃（前一行结尾的 \\ 会让续行
    自然接到下一行），最后再兜底清掉可能悬空的结尾反斜杠。
    """
    lines = text.split("\n")
    out = []
    i = 0
    touched = []
    while i < len(lines):
        if not re.match(r"^\s*DEFAULT_PACKAGES\s*\+?=", lines[i]):
            out.append(lines[i])
            i += 1
            continue

        # 收集整个续行块
        blk = [lines[i]]
        i += 1
        while blk[-1].rstrip().endswith("\\") and i < len(lines):
            blk.append(lines[i])
            i += 1

        new_blk = [blk[0]]  # 首行 "DEFAULT_PACKAGES += \" 原样保留
        for ln in blk[1:]:
            cont = ln.rstrip().endswith("\\")
            body = ln.rstrip()[:-1].rstrip() if cont else ln.rstrip()
            toks = body.split()

            kept = []
            for t in toks:
                if t in DROP_TOKENS:
                    touched.append(t)
                    continue
                for a, b in SWAPS:
                    if t == a:
                        touched.append("%s->%s" % (a, b))
                        t = b
                        break
                kept.append(t)

            if not kept:
                # 这一行被删空：整行丢弃（上一行的续行反斜杠会接到下一行）
                continue
            new_blk.append("\t" + " ".join(kept) + (" \\" if cont else ""))

        # 兜底：最后一行不能以裸反斜杠结尾，否则会把后面的语句吞进来
        if new_blk[-1].rstrip().endswith("\\"):
            new_blk[-1] = new_blk[-1].rstrip()[:-1].rstrip()

        out.extend(new_blk)

    return "\n".join(out), touched


def main():
    mk = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_MK
    try:
        with open(mk, encoding="utf-8") as f:
            src = f.read()
    except OSError as e:
        print("!! 错误：读不到 %s（%s）" % (mk, e))
        return 2

    if "ipq40xx" not in mk:
        print("!! 错误：%s 看起来不是 ipq40xx 的 target Makefile，拒绝修改" % mk)
        return 2

    text = patch_features(src)
    text, touched = patch_default_packages(text)

    if text == src:
        print("==> %s 已精简过（无变化），跳过" % mk)
        return 0

    # 硬校验：不该留的包确实没了，该换的确实换上了
    bad = []
    for t in DROP_TOKENS:
        if re.search(r"(?<![\w-])" + re.escape(t) + r"(?![\w-])", text):
            bad.append("仍存在 " + t)
    if "wpad-openssl" in text:
        bad.append("wpad-openssl 未替换")
    if "wpad-basic" not in text:
        bad.append("wpad-basic 未写入")
    if re.search(r"(?m)^\s*\\\s*$", text):
        bad.append("存在悬空的续行反斜杠")
    if bad:
        print("!! 错误：精简结果校验失败 —— " + "；".join(bad))
        return 1

    with open(mk, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)

    print("==> ipq40xx 强制包瘦身完成（%s）" % mk)
    print("    处理项：" + ("、".join(touched) if touched else "（无）"))
    # 回显改后的两段，便于 CI 日志一眼核对
    for label, pat in (
        ("FEATURES", r"(?m)^FEATURES(?::|\+)?=.*$"),
        ("DEFAULT_PACKAGES", r"(?ms)^DEFAULT_PACKAGES\s*\+?=.*?(?<!\\)$"),
    ):
        m = re.search(pat, text)
        if m:
            print("    --- %s ---" % label)
            for ln in m.group(0).rstrip().split("\n"):
                print("    " + ln)
    return 0


if __name__ == "__main__":
    sys.exit(main())
