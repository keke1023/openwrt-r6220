#!/usr/bin/env python3
"""
把 OpenWrt rockchip/armv8 的 02_network 里 NanoPi R2S 的 LAN/WAN 对调。

背景
----
友善官方定义：
    eth0 = 板载原生 GMAC          （官方定义为 WAN）
    eth1 = USB3 转网口 RTL8153B   （官方定义为 LAN）

上游 25.12 的 02_network 把 r2s 塞在一堆设备共享的 case 行里：
    ucidef_set_interfaces_lan_wan 'eth1' 'eth0'    => lan=eth1, wan=eth0

本仓库正式固件（23.05 线）在 scripts/diy-part2.sh 里已把 R2S 拆成独立分支并改成
    lan=eth0, wan=eth1
即「USB 网口做 WAN」，用户接线习惯基于此。主线验证版（25.12）不含 diy-part2.sh，
若不做同样处理，刷完 LAN/WAN 会与现状相反。

⚠️ 关键坑（v25.12.6 实测）
--------------------------
`friendlyarm,nanopi-r2s|\\` 这行在 02_network 里出现 **两次**：
    第 13 行 —— rockchip_setup_interfaces() 的网口分配 case（要改）
    第 80 行 —— rockchip_setup_macs() 的 MAC 生成 case（**绝不能碰**）
所以「全局正则替换」或「匹配必须唯一」都不成立。本脚本先把文件切成
rockchip_setup_interfaces() 的函数体，只在该函数体内做增删，函数外一字不动。

另一处隐患：原共享行紧邻
    friendlyarm,nanopi-r2s|\\
    friendlyarm,nanopi-r2s-plus|\\
若用宽松正则 `friendlyarm,nanopi-r2s[^\\n]*\\n` 会把 r2s-plus 那行一起吃掉，
导致 r2s-plus 设备失去网口配置。这里改为精确匹配「行尾必须是 | 加反斜杠」。

用法
----
    python3 diy-r2s-lanwan.py <path/to/02_network>

幂等：已是对调后的独立分支则直接退出 0。
"""

import re
import sys

FUNC = "rockchip_setup_interfaces"
SHARED_LINE = re.compile(r"^[ \t]*friendlyarm,nanopi-r2s\|\\[ \t]*\n", re.M)
EXPECTED = "\t\tucidef_set_interfaces_lan_wan 'eth0' 'eth1'\n"


def split_func(src: str, name: str):
    """把 src 切成 (func 之前的文本, func 函数体, func 之后的文本)。

    用 `^name()` 定位函数头、花括号配平定位函数尾，避免依赖缩进风格。
    """
    m = re.search(rf"^{re.escape(name)}\(\)[ \t]*\n", src, re.M)
    if not m:
        return None
    start = m.start()

    brace = src.find("{", m.end())
    if brace < 0:
        return None
    depth = 0
    i = brace
    while i < len(src):
        ch = src[i]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                # 函数结束，连同换行一起切
                end = src.find("\n", i)
                end = len(src) if end < 0 else end + 1
                return src[:start], src[start:end], src[end:]
        i += 1
    return None


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: diy-r2s-lanwan.py <02_network>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    try:
        # newline="" → 不做换行符翻译，原样读入（CI 是 LF，本地 Windows 可能是 CRLF）
        with open(path, encoding="utf-8", newline="") as f:
            src = f.read()
    except OSError as exc:
        print(f"!! 读取失败: {exc}", file=sys.stderr)
        return 1

    parts = split_func(src, FUNC)
    if not parts:
        print(f"!! 未能定位 {FUNC}() 函数体", file=sys.stderr)
        return 1
    head, body, tail = parts

    # 幂等：函数体内已有 r2s 独立分支
    if re.search(r"^[ \t]*friendlyarm,nanopi-r2s\)[ \t]*$", body, re.M):
        print(f"已是对调后的独立分支（{FUNC} 内），跳过")
        return 0

    # 1) 从共享行里摘掉 r2s（必须恰好 1 处，且只在本函数体内）
    new_body, n = SHARED_LINE.subn("", body)
    if n != 1:
        print(
            f"!! {FUNC}() 内 r2s 共享行匹配 {n} 处（期望 1），拒绝改动",
            file=sys.stderr,
        )
        return 1

    # 2) 在 case 分支体开头插入独立分支
    anchor_re = re.compile(r'^([ \t]*)case "\$board" in\n', re.M)
    m = anchor_re.search(new_body)
    if not m:
        print('!! 未找到 case "$board" in 入口', file=sys.stderr)
        return 1

    indent = m.group(1)
    insert = (
        f"{indent}friendlyarm,nanopi-r2s)\n"
        f"{indent}\tucidef_set_interfaces_lan_wan 'eth0' 'eth1'\n"
        f"{indent}\t;;\n"
    )
    new_body = new_body[: m.end()] + insert + new_body[m.end() :]

    # 3) 自检：函数体内必须出现目标行，且原共享行已消失
    if EXPECTED.strip() not in new_body:
        print("!! 插入后未找到目标 lan/wan 配置行", file=sys.stderr)
        return 1
    if SHARED_LINE.search(new_body):
        print("!! 共享行未被清除", file=sys.stderr)
        return 1

    # newline="\n" → 强制 LF 落盘。绝不能依赖默认值：Windows 本地跑会把整个文件
    # 变成 CRLF（diff 显示全文件改动），而 CI 是 LF。统一写 LF 两边行为一致。
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(head + new_body + tail)

    print(f"patched {path}: {FUNC}() 内 r2s 改为 lan=eth0 wan=eth1")
    print(f"  （{FUNC}() 之外的 r2s 出现（如 rockchip_setup_macs）未受影响）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
