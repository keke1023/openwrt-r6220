#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
xray-core 体积精简 v3 —— 改用 OpenWrt 标准 patches 机制（不再覆盖 Build/Prepare）

【为什么 v1/v2 无效】
v1/v2 往 xray-core/Makefile 里注入 `define Build/Prepare`，实测两轮 CI 产出的
xray 二进制 md5 完全一致（23,713,500 B），grpc / commander / quic-go 全都还在。
说明注入的 Build/Prepare 根本没被执行 —— 覆盖这个 hook 在 OpenWrt 里不可靠。

v3 改走官方机制：把改动做成 unified diff 放进包的 `patches/` 目录。
`include/package-defaults.mk` 里
    Build/Patch:=$(Build/Patch/Default)
    PATCH_DIR?=./patches
    define Build/Prepare/Default
        $(PKG_UNPACK)
        $(Build/Patch)
    endef
即 Prepare 阶段会**无条件**按 `PATCH_DIR` 应用补丁，不存在被覆盖的可能。

【补丁内容】
001-slim-modules.patch
    删 main/distro/all/all.go 里 12 个空导入（协议/传输层）。
    xray 用 `_ "github.com/xtls/xray-core/..."` 做编译期注册，Go 只链接被引用的包，
    删掉后对应实现及其第三方依赖（quic-go 等）完全不参与编译。

002-drop-grpc-api.patch
    删 all.go 里 4 个 gRPC API 模块 + 改 main/commands/all/commands.go，
    去掉 `api` 的 import 与 `api.CmdAPI`，切断 CLI 侧的 grpc 引用链。
    原因：app/commander、app/log/command、app/proxyman/command、app/stats/command
    全都 import grpc，而 main/commands/all 又 import main/commands/all/api，
    api 再把这四个包拉一遍 —— 只删 transport/internet/grpc（传输层）等于白删。

    安全性已核实：luci-app-ssr-plus 187-2 的 gen_config.lua 生成的 Xray 配置里
    `api` / `stats` / `policy` 出现 0 次，只有 log / inbounds / outbounds / routing；
    init.d 与 control.lua 也没有 `xray api` 调用 → 删掉后 ssr-plus 照常启动。

003-drop-tls-grpc.patch
    切断 grpc 全链（6 个文件，230 行）：
      1) transport/internet/tls/grpc.go 掏空 —— tls 包自己 import grpc/credentials
         （NewGrpcUtls），而 tls 为 reality 必须保留，这是 v3 首轮只省 37 KB 的元凶；
      2) infra/conf/grpc.go 掏空 —— 切断 conf -> transport/internet/grpc 传输层；
      3) infra/conf/api.go 掏空 —— 切断 conf -> app/commander + 5 个 command 服务。
         ★ 这才是 grpc-go 一直留在二进制里的真正原因：配置解析器 import commander；
      4) infra/conf/transport.go 删 GRPCConfig/GUNConfig 字段与 Build 分支；
      5) infra/conf/transport_internet.go 删 StreamConfig 同名字段与 Build 分支；
      6) infra/conf/xray.go 删 API 字段 + Override 块 + Build 块。
    实测（run 41458593954）：xray 23,675,652 -> 21,537,356 B（-2.04 MiB），
    二进制内 google.golang.org/grpc / transport/internet/grpc 命中数均为 0，
    vless 217 次、realitySettings 2 次、transport/internet/tls 193 次，功能基石完好。
    安全性：ssr-plus gen_config.lua 不生成 api 段，init.d 无 `xray api` 调用；
    配置若残留 "api" 字段会被 json 静默忽略。

004-drop-wireguard-quic.patch
    再砍三块（2026-11-03，7 个文件 585 行）：
      1) wireguard outbound：掏空 infra/conf/wireguard.go + 删 xray.go 的
         "wireguard" 注册行 -> 带走 proxy/wireguard -> 带走整条 gvisor netstack
         （gvisor 全仓只被 proxy/wireguard 引用，是最大的一头）；
      2) QUIC 传输：删 infra/conf/transport{,_internet}.go 的 QUICConfig 与
         transport/internet/quic 引用；
      3) DoQ + QUIC 嗅探：掏空 app/dns/nameserver_quic.go、删 nameserver.go 的
         quic+local 分支、删 app/dispatcher/sniffer.go 的 quic.SniffQUIC 注册
         -> quic-go 本体随之退出。
    影响：vless+reality / vmess / trojan / ss 全不受影响；不使用 QUIC 传输、
    WireGuard 出站与 DoQ 解析即可。配置若引用这些协议会报 unknown protocol。

【保留】
vless(in/out) + reality + tls + tcp + udp + websocket + http + vmess + shadowsocks +
trojan + socks + dokodemo + freedom + blackhole + dns + dispatcher/proxyman/router/
stats/policy/log。vless+reality 完整可用；SS/SSR 走 shadowsocks-libev 独立二进制。

用法：
  python3 patch-xray-slim.py package/helloworld/xray-core
  python3 patch-xray-slim.py package/helloworld/xray-core/Makefile   # 兼容旧调用

幂等：补丁文件内容一致则跳过；若检测到 v1/v2 注入的 Build/Prepare 残留会自动清除。
"""

import os
import shutil
import sys

PATCH_NAMES = [
    "001-slim-modules.patch",
    "002-drop-grpc-api.patch",
    "003-drop-tls-grpc.patch",
    "004-drop-wireguard-quic.patch",
]

# v1/v2 注入块的起始标记（需清理掉，否则 Build/Prepare 覆盖会干扰判断）
LEGACY_MARKS = [
    "# ---- xray 体积精简 v2",
    "XRAY_SLIM_MODULES :=",
]


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

    # 往回吃掉紧邻的注释行与空行（v2 注入时块前总带一个空行）
    while start > 0 and (lines[start - 1].lstrip().startswith("#") or not lines[start - 1].strip()):
        start -= 1

    end = -1
    for j in range(start, len(lines)):
        if lines[j].strip() == "endef":
            end = j
            break
        # 没有 endef 就退到 XRAY_SLIM_MODULES 连续块结束
    if end < 0:
        end = start
        while end + 1 < len(lines) and lines[end + 1].strip().startswith(("\t", "XRAY_SLIM")):
            end += 1

    removed = end - start + 1
    del lines[start:end + 1]
    # 块尾部自带的空行也一并收掉
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
    if target.endswith("Makefile"):
        pkg_dir = os.path.dirname(target) or "."
    else:
        pkg_dir = target

    if not os.path.isdir(pkg_dir):
        print("!! 错误：找不到包目录 %s" % pkg_dir, file=sys.stderr)
        return 2

    here = os.path.dirname(os.path.abspath(__file__))
    src_dir = os.path.join(here, "xray-patches")
    if not os.path.isdir(src_dir):
        print("!! 错误：找不到补丁源目录 %s" % src_dir, file=sys.stderr)
        return 2

    dst_dir = os.path.join(pkg_dir, "patches")
    os.makedirs(dst_dir, exist_ok=True)

    changed = 0
    for name in PATCH_NAMES:
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
        hunks = data.count(b"\n@@ ") + data.count(b"@@ -") - data.count(b"\n@@ ")
        print("    %-28s 已写入（%d B）" % (name, len(data)))

    strip_legacy_block(os.path.join(pkg_dir, "Makefile"))

    print("==> xray 精简 v3 就绪：补丁位于 %s（%d 个）" % (dst_dir, len(PATCH_NAMES)))
    print("    Prepare 阶段由 Build/Patch 自动应用（PATCH_DIR=./patches），无需改 Makefile")
    print("    预期：google.golang.org/grpc / gvisor / quic-go 全部退出编译")
    print("    已完成：003 砍 grpc-gRPC（-2.04 MiB）；004 砍 wireguard+gvisor / QUIC / DoQ")
    return 0


if __name__ == "__main__":
    sys.exit(main())
