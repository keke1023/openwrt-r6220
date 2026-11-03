#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
xray-core 体积精简 —— 按 xray 版本自动选择补丁集

【为什么用 patches 目录，而不是覆盖 Build/Prepare】
v1/v2 曾往 xray-core/Makefile 里注入 `define Build/Prepare`，实测两轮 CI 产出的
xray 二进制 md5 完全一致（23,713,500 B），grpc / commander / quic-go 全都还在 ——
说明注入的 hook 根本没被执行，覆盖这个 hook 在 OpenWrt 里不可靠。

v3 改走官方机制：把改动做成 unified diff 放进包的 `patches/` 目录。
  include/package-defaults.mk 里
      Build/Patch:=$(Build/Patch/Default)
      PATCH_DIR?=./patches
      define Build/Prepare/Default
          $(PKG_UNPACK)
          $(Build/Patch)
      endef
Prepare 阶段会**无条件**按 PATCH_DIR 应用，不存在被覆盖的可能。

【补丁集：按版本分目录，改动逻辑一致但源码结构不同】
xray 在 1.8.4 → 1.8.24 之间做过较大重构（新增 splithttp/httpupgrade、conf 层
拆分了 QUIC/SplitHTTP 配置），同一份 diff 无法通用：实测把 1.8.4 那套补丁直接
喂给 1.8.24，11 个文件全部 reject。所以按版本各存一套：

  xray-patches/1.8.4/   萤石 W3（原厂 16MB）在用，4 个补丁
    001 删 all.go 12 个空导入
    002 删 all.go 4 个 gRPC API 模块 + CLI 的 api 子命令
    003 grpc 全链（tls/grpc.go + conf/{grpc,api}.go + 字段与 Build 分支）
    004 wireguard/gvisor + QUIC 传输 + DoQ + QUIC 嗅探
    实测：xray 23,713,500 -> 21,537,356（003），再加 004 后 squashfs
          11.010 -> 9.309 MiB，overlay 149.7 KiB -> 约 1.6 MiB

  xray-patches/1.8.24/  K2P / WR1200JS / a3004ns-dual 在用，5 个补丁
    001 删 all.go 13 个空导入（比 1.8.4 多一个 splithttp）
    002 删 commander + 4 个 gRPC API 服务（all.go）+ CLI 的 api 子命令
        ★ 只删 CLI 不够：conf 的 api 段仍会 import commander，grpc-go 照样链接
    003 grpc 全链（同上，6 个文件）
    004 wireguard 出站（conf/wireguard.go + xray.go 协议表两行）
    005 QUIC 传输 + DoQ + QUIC 嗅探 + splithttp/HTTP3
        ★ 1.8.24 新增的 splithttp 自带 HTTP/3（quic-go/http3），是 quic-go 的
          第四个入口；不砍它，quic-go 会从这条路重新被链进来
    预期：与 1.8.4 那套同构，xray 未压缩约 -29%

【安全性（两套通用）】
luci-app-ssr-plus 的 gen_config.lua 生成的 Xray 配置里 `api` / `stats` / `policy`
出现 0 次，只有 log / inbounds / outbounds / routing；init.d 与 control.lua 也没有
`xray api` 调用 → 删掉 commander 与 gRPC API 不影响启动。
vless+reality+vision 走 tcp+tls+reality，全部保留；vmess / trojan / ss / socks /
ws / h2 / httpupgrade 也保留。SS/SSR 走 shadowsocks-libev 独立二进制，不受影响。
代价：不支持 QUIC 传输、WireGuard 出站、DoQ 解析、SplitHTTP/HTTP3；
配置里若写了这些协议，加载时会报 unknown protocol（不会静默降级）。

用法：
  python3 patch-xray-slim.py package/helloworld/xray-core
  python3 patch-xray-slim.py package/helloworld/xray-core/Makefile   # 兼容旧调用

幂等：内容一致则跳过；检测到 v1/v2 注入的 Build/Prepare 残留会自动清除。
版本不在支持表里时**直接失败**（exit 1），不静默跳过 —— 16MB 机型跳过精简
等于固件必然超分区，早失败比晚失败好定位。
"""

import os
import re
import shutil
import sys

# 版本 -> 补丁文件名列表。新增版本时在这里加一条，并在 xray-patches/<版本>/ 放补丁。
PATCH_SETS = {
    "1.8.4": [
        "001-slim-modules.patch",
        "002-drop-grpc-api.patch",
        "003-drop-tls-grpc.patch",
        "004-drop-wireguard-quic.patch",
    ],
    "1.8.24": [
        "001-slim-modules.patch",
        "002-drop-grpc-api.patch",
        "003-drop-grpc-chain.patch",
        "004-drop-wireguard.patch",
        "005-drop-quic-http3.patch",
    ],
}

# v1/v2 注入块的起始标记（需清理掉，否则 Build/Prepare 覆盖会干扰判断）
LEGACY_MARKS = [
    "# ---- xray 体积精简 v2",
    "XRAY_SLIM_MODULES :=",
]

PATCH_NAME_RE = re.compile(r"^\d{3}-[A-Za-z0-9._-]+\.patch$")


def read_pkg_version(pkg_dir):
    """从 xray-core/Makefile 读 PKG_VERSION。"""
    mk = os.path.join(pkg_dir, "Makefile")
    if not os.path.isfile(mk):
        return None
    with open(mk, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"^PKG_VERSION:=\s*(\S+)", line.strip())
            if m:
                return m.group(1)
    return None


def strip_legacy_block(mk_path):
    """删掉 v1/v2 注入的注释块 + define Build/Prepare ... endef。返回是否改动。"""
    if not os.path.isfile(mk_path):
        return False
    with open(mk_path, "r", encoding="utf-8", errors="surrogateescape", newline="") as f:
        raw = f.read()
    crlf = "\r\n" in raw
    lines = raw.replace("\r\n", "\n").split("\n")

    start = -1
    for i, ln in enumerate(lines):
        if any(m in ln for m in LEGACY_MARKS):
            start = i
            break
    if start < 0:
        return False

    while start > 0 and (lines[start - 1].lstrip().startswith("#") or not lines[start - 1].strip()):
        start -= 1

    end = -1
    for j in range(start, len(lines)):
        if lines[j].strip() == "endef":
            end = j
            break
    if end < 0:
        end = start
        while end + 1 < len(lines) and lines[end + 1].strip().startswith(("\t", "XRAY_SLIM")):
            end += 1

    removed = end - start + 1
    del lines[start:end + 1]
    if start < len(lines) and not lines[start].strip():
        del lines[start]

    out = "\n".join(lines)
    while "\n\n\n" in out:
        out = out.replace("\n\n\n", "\n\n")
    if crlf:
        out = out.replace("\n", "\r\n")
    with open(mk_path, "w", encoding="utf-8", errors="surrogateescape", newline="") as f:
        f.write(out)
    print("==> 已清除 v1/v2 残留的 Build/Prepare 注入块（%d 行）" % removed)
    return True


def main():
    if len(sys.argv) < 2:
        print("用法: patch-xray-slim.py <xray-core 包目录或 Makefile 路径>", file=sys.stderr)
        return 2

    target = sys.argv[1]
    pkg_dir = os.path.dirname(target) if target.endswith("Makefile") else target
    pkg_dir = pkg_dir or "."

    if not os.path.isdir(pkg_dir):
        print("!! 错误：找不到包目录 %s" % pkg_dir, file=sys.stderr)
        return 2

    ver = read_pkg_version(pkg_dir)
    if not ver:
        print("!! 错误：无法从 %s/Makefile 读取 PKG_VERSION" % pkg_dir, file=sys.stderr)
        return 2
    if ver not in PATCH_SETS:
        print("!! 错误：xray v%s 没有对应的精简补丁集（支持：%s）"
              % (ver, ", ".join(sorted(PATCH_SETS))), file=sys.stderr)
        print("   若确实要构建该版本且分区够大，请在 diy-part1.sh 里关掉精简门控；"
              "否则请按现有补丁的结构为新版本补一套 xray-patches/%s/" % ver, file=sys.stderr)
        return 1

    names = PATCH_SETS[ver]
    here = os.path.dirname(os.path.abspath(__file__))
    src_dir = os.path.join(here, "xray-patches", ver)
    if not os.path.isdir(src_dir):
        print("!! 错误：找不到补丁源目录 %s" % src_dir, file=sys.stderr)
        return 2

    dst_dir = os.path.join(pkg_dir, "patches")
    os.makedirs(dst_dir, exist_ok=True)

    # 清掉别的版本残留的补丁，避免两套混用（包本身不带 patches，故只匹配 NNN-*.patch）
    for fn in sorted(os.listdir(dst_dir)):
        if PATCH_NAME_RE.match(fn) and fn not in names:
            os.remove(os.path.join(dst_dir, fn))
            print("    清除异版本残留补丁 %s" % fn)

    changed = 0
    for name in names:
        src = os.path.join(src_dir, name)
        dst = os.path.join(dst_dir, name)
        if not os.path.isfile(src):
            print("!! 错误：缺少补丁 %s" % src, file=sys.stderr)
            return 1
        with open(src, "rb") as f:
            data = f.read()
        if os.path.isfile(dst):
            with open(dst, "rb") as f:
                if f.read() == data:
                    print("    %-28s 已存在且一致，跳过" % name)
                    continue
        shutil.copyfile(src, dst)
        changed += 1
        print("    %-28s 已写入（%d B）" % (name, len(data)))

    strip_legacy_block(os.path.join(pkg_dir, "Makefile"))

    print("==> xray v%s 精简就绪：%d 个补丁位于 %s（新写入 %d 个）"
          % (ver, len(names), dst_dir, changed))
    print("    Prepare 阶段由 Build/Patch 自动应用（PATCH_DIR=./patches），无需改 Makefile")
    if ver == "1.8.4":
        print("    预期：google.golang.org/grpc / gvisor / quic-go 全部退出编译")
        print("    实测：xray 23,713,500 -> 21,537,356 B（003），再加 004 后 squashfs 9.309 MiB")
    else:
        print("    预期：google.golang.org/grpc / gvisor / quic-go(含 http3) 全部退出编译")
        print("    结构同 1.8.4 那套；005 额外砍掉 1.8.24 新增的 splithttp/HTTP3")
    return 0


if __name__ == "__main__":
    sys.exit(main())
