#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
给 helloworld 的 xray-core 加一个 Build/Prepare 覆盖，在源码解压之后
把 main/distro/all/all.go 里体积最大的那些「可选模块」空导入删掉。

原理：xray 的 main/distro/all/all.go 用一堆 `_ "github.com/xtls/xray-core/..."` 
空导入做编译期注册。Go 只会链接被引用的包，删掉这些空导入后，
对应的协议/传输实现（以及它们的第三方依赖，比如 quic-go、grpc、protobuf）
就完全不参与编译，二进制直接瘦一大圈。

删掉的（本机型用不到）：
  transport/internet/quic          -> quic-go，最大的一块（约 4MB 代码）
  transport/internet/grpc          -> google.golang.org/grpc + protobuf（约 3MB）
  transport/internet/kcp           -> mkcp 传输
  transport/internet/domainsocket  -> unix socket 传输
  proxy/wireguard                  -> WireGuard 出站
  proxy/loopback                   -> loopback 出站
  app/reverse                      -> 反向代理
  app/metrics                      -> 指标导出
  app/observatory(+command)        -> 观测/健康检查
  main/toml, main/yaml             -> 非 JSON 配置解析器

保留的：vless(in/outbound)、reality、tls、tcp、udp、websocket、http、
vmess、shadowsocks、trojan、socks、dokodemo、freedom、blackhole、dns，
以及 dispatcher/proxyman/router/stats/policy/log 等必需 app。
→ vless+reality 完整可用，SS/SSR（走 shadowsocks-libev，独立二进制）不受影响。

用法：
  python3 patch-xray-slim.py package/helloworld/xray-core/Makefile

幂等：Makefile 里已有 XRAY_SLIM_MODULES 标记就直接跳过，不改第二次。
"""

import sys
import os

MARKER = "XRAY_SLIM_MODULES"

# 要剔除的模块（相对 github.com/xtls/xray-core/ 的子路径）
DROP = [
    "transport/internet/quic",
    "transport/internet/grpc",
    "transport/internet/kcp",
    "transport/internet/domainsocket",
    "proxy/wireguard",
    "proxy/loopback",
    "app/reverse",
    "app/metrics",
    "app/observatory",
    "app/observatory/command",
    "main/toml",
    "main/yaml",
]

BLOCK = """# ---- xray 体积精简（scripts/patch-xray-slim.py 注入，勿手改）----
# 删掉 all.go 里的空导入 = 对应包不参与编译。省下的是 quic-go / grpc / protobuf
# 这几坨第三方依赖，是 16MB flash 上最肥的一块。
XRAY_SLIM_MODULES := \\
%s

define Build/Prepare
\t$(call Build/Prepare/Default)
\t@echo "==> xray 精简：从 all.go 剔除 $(words $(XRAY_SLIM_MODULES)) 个可选模块"
\t@for m in $(XRAY_SLIM_MODULES); do \\
\t\tsed -i "\\|github.com/xtls/xray-core/$$m\\"|d" $(PKG_BUILD_DIR)/main/distro/all/all.go || exit 1; \\
\tdone
\t@n=$$(grep -c '^[[:space:]]*_ "' $(PKG_BUILD_DIR)/main/distro/all/all.go || true); \\
\t\techo "==> all.go 剩余注册行: $$n（精简前 55 行左右）"
endef
"""


def build_block():
    mods = " \\\n".join("\t" + m for m in DROP)
    return BLOCK % mods


def main():
    if len(sys.argv) < 2:
        print("用法: patch-xray-slim.py <xray-core Makefile 路径>", file=sys.stderr)
        return 2

    path = sys.argv[1]
    if not os.path.isfile(path):
        print("!! 错误：找不到 %s" % path, file=sys.stderr)
        return 2

    with open(path, "r", encoding="utf-8", errors="surrogateescape") as f:
        src = f.read()

    if MARKER in src:
        print("==> xray 精简补丁已存在，跳过（幂等）")
        return 0

    # 插在 include $(INCLUDE_DIR)/package.mk 之后：package.mk 定义了
    # Build/Prepare/Default，而 golang-package.mk 只覆盖 Build/Compile，
    # 所以在此处定义 Build/Prepare 不会冲掉 Go 的构建逻辑。
    anchor = "include $(INCLUDE_DIR)/package.mk"
    idx = src.find(anchor)
    if idx < 0:
        anchor = "define Package/xray-core"
        idx = src.find(anchor)
        if idx < 0:
            print("!! 错误：Makefile 里找不到插入锚点（package.mk include / Package/xray-core）",
                  file=sys.stderr)
            return 1
        insert_at = idx
        print("==> 警告：未找到 package.mk include，改为插在 define Package/xray-core 之前")
    else:
        insert_at = idx + len(anchor)
        # 吃掉该行剩余部分直到换行
        nl = src.find("\n", insert_at)
        insert_at = (nl + 1) if nl >= 0 else len(src)

    block = "\n" + build_block() + "\n"
    out = src[:insert_at] + block + src[insert_at:]

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)

    print("==> 已注入 xray 精简 Build/Prepare（%d 个模块）" % len(DROP))
    for m in DROP:
        print("     - %s" % m)
    print("==> Makefile: %s (%d 行)" % (path, out.count("\n")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
