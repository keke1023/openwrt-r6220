#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
从 include/target.mk 的 DEFAULT_PACKAGES 里摘掉指定的默认包（默认只摘 opkg）。

背景：opkg / dropbear 在 18.06 是 include/target.mk 的 DEFAULT_PACKAGES 硬编码项，
`.config` 里写 CONFIG_PACKAGE_xxx=n 会被 defconfig 按默认值翻回 =y，
而仓库的 kconfig 反向校验会因为「=n 变 =y」直接判定构建失败。
所以只能从 target.mk 层面摘。

安全性（已用固件内的 opkg 元数据核实）：
  - 176 个包的 Depends 里，没有任何一个依赖 opkg
  - luci-lib-ipkg 只依赖 libc + luci-base，不会再把它拉回来
  - 镜像组装用的是宿主侧 opkg-cl，摘掉目标端 opkg 不影响打包
  - luci 元包的 LUCI_DEPENDS（uhttpd / uhttpd-mod-ubus / luci-mod-admin-full /
    luci-theme-bootstrap / luci-app-firewall / luci-proto-ppp / libiwinfo-lua /
    rpcd-mod-rrdns）不含 dropbear，18.06 也没有 luci-app-dropbear 这个包
  - dropbear 只被 failsafe 脚本「运行时调用」，不是包依赖；摘掉后 failsafe
    只剩串口登录，Web(uhttpd) 管理不受影响

副作用：
  - 摘 opkg     → LuCI「软件包」页面失效，运行期无法再装包
  - 摘 dropbear → 没有 SSH，只能走 LuCI，串口是唯一兜底

用法：
  python3 patch-drop-opkg.py [include/target.mk 路径]
  DROP_DEFAULT_PKGS="opkg dropbear" python3 patch-drop-opkg.py [路径]

幂等：block 里已无目标包就跳过。
"""

import os
import re
import sys

DEFAULT_PATH = "include/target.mk"


def patch(src, pkgs):
    lines = src.split("\n")
    out = []
    removed = []
    in_block = False

    for ln in lines:
        # DEFAULT_PACKAGES:= 后面直接跟反斜杠续行的起始
        if re.match(r"^\s*DEFAULT_PACKAGES\s*:?=\s*\\\s*$", ln):
            in_block = True
            out.append(ln)
            continue

        if in_block:
            token = ln.strip().rstrip("\\").strip()
            if token in pkgs:
                removed.append(token)
                # 判断这一行是否还带续行反斜杠
                if not ln.rstrip().endswith("\\") and out and out[-1].rstrip().endswith("\\"):
                    # 被删的是块尾，去掉上一行的续行符，避免悬空反斜杠
                    out[-1] = out[-1].rstrip()[:-1].rstrip()
                    in_block = False
                continue
            if not ln.rstrip().endswith("\\"):
                in_block = False

        out.append(ln)

    return "\n".join(out), removed


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PATH
    pkgs = set((os.environ.get("DROP_DEFAULT_PKGS") or "opkg").split())
    if not pkgs:
        pkgs = {"opkg"}

    if not os.path.isfile(path):
        print("!! 警告：找不到 %s，跳过默认包摘除" % path, file=sys.stderr)
        return 1

    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    new, removed = patch(src, pkgs)

    if not removed:
        print("==> %s 的 DEFAULT_PACKAGES 里已无 [%s]，跳过（幂等）"
              % (path, " ".join(sorted(pkgs))))
        return 0

    if new == src:
        print("!! 错误：匹配到目标包但内容未变化", file=sys.stderr)
        return 1

    # 悬空反斜杠自检：任何以 "\" 结尾且下一行是空行/文件尾都不合法
    ls = new.split("\n")
    for i, ln in enumerate(ls):
        if ln.rstrip().endswith("\\"):
            nxt = ls[i + 1] if i + 1 < len(ls) else ""
            if not nxt.strip():
                print("!! 错误：第 %d 行出现悬空续行反斜杠" % (i + 1), file=sys.stderr)
                return 1

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(new)

    print("==> 已从 %s 的 DEFAULT_PACKAGES 摘除：%s（%d 处）"
          % (path, ", ".join(removed), len(removed)))
    # 回显改后的块，便于在 CI 日志里核对
    in_block = False
    for ln in new.split("\n"):
        if re.match(r"^\s*DEFAULT_PACKAGES\s*:?=\s*\\\s*$", ln):
            in_block = True
            print("     " + ln.strip())
            continue
        if in_block:
            print("     " + ln.strip())
            if not ln.rstrip().endswith("\\"):
                break
    return 0


if __name__ == "__main__":
    sys.exit(main())
