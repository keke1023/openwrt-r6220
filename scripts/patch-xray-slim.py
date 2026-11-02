#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
给 helloworld 的 xray-core 加一个 Build/Prepare 覆盖，在源码解压之后做两件事：

【A】删掉 main/distro/all/all.go 里用不到的空导入
     xray 用 `_ "github.com/xtls/xray-core/..."` 做编译期注册。Go 只链接被引用的包，
     删掉这些空导入后，对应实现及其第三方依赖就完全不参与编译。

【B】摘掉 CLI 的 api 子命令，真正切断 gRPC 依赖链
     v1 只删了 transport/internet/grpc（传输层），但下面这些包全都
     `import "google.golang.org/grpc"`：
         app/commander             （API 服务宿主）
         app/log/command           （LoggerService）
         app/proxyman/command      （HandlerService）
         app/stats/command         （StatsService）
     而 main/commands/all 又 import main/commands/all/api，
     api 再把这四个包拉一遍 —— 所以 v1 的 grpc 实际白删。
     v2 必须同时改 main/commands/all/commands.go，删掉 api 的 import 和 api.CmdAPI。

     安全性已核实：luci-app-ssr-plus 187-2 的
     root/usr/share/shadowsocksr/gen_config.lua 生成的 Xray 配置里，
     `api` / `stats` / `policy` 出现 0 次，只有 log / inbounds / outbounds / routing；
     init.d 与 control.lua 也没有 `xray api` 调用。
     → 删掉 commander 链后 ssr-plus 照常启动，不存在「配置里有 api 段却无 app 注册」的风险。

删掉的模块清单：
  A 组（协议/传输，本机型用不到）
    transport/internet/quic          -> quic-go
    transport/internet/grpc          -> gRPC 传输层
    transport/internet/kcp           -> mkcp
    transport/internet/domainsocket  -> unix socket
    proxy/wireguard, proxy/loopback, app/reverse, app/metrics
    app/observatory(+command), main/toml, main/yaml
  B 组（gRPC API 链，本次新增）
    app/commander, app/log/command, app/proxyman/command, app/stats/command

保留：vless(in/out) + reality + tls + tcp + udp + websocket + http + vmess +
shadowsocks + trojan + socks + dokodemo + freedom + blackhole + dns +
dispatcher/proxyman/router/stats/policy/log。
→ vless+reality 完整可用；SS/SSR 走 shadowsocks-libev 独立二进制，不受影响。

用法：
  python3 patch-xray-slim.py package/helloworld/xray-core/Makefile

幂等：Makefile 里已有 XRAY_SLIM_VERSION := 2 就直接跳过。
"""

import sys
import os

VERSION_MARK = "XRAY_SLIM_VERSION := 2"
LEGACY_MARK = "XRAY_SLIM_MODULES"

# A 组：协议 / 传输
DROP_TRANSPORT = [
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

# B 组：gRPC API 链（删完这组，google.golang.org/grpc 才真正退出编译）
DROP_GRPC_API = [
    "app/commander",
    "app/log/command",
    "app/proxyman/command",
    "app/stats/command",
]

DROP = DROP_TRANSPORT + DROP_GRPC_API

BLOCK = """# ---- xray 体积精简 v2（scripts/patch-xray-slim.py 注入，勿手改）----
# A 组：删 all.go 空导入 => 对应包不参与编译，顺带甩掉 quic-go 等第三方依赖
# B 组：删 commander 及三个 */command => 切断 google.golang.org/grpc
#       同时改 main/commands/all/commands.go，摘掉 CLI 的 api 子命令
XRAY_SLIM_VERSION := 2
XRAY_SLIM_MODULES := \\
%s

define Build/Prepare
\t$(call Build/Prepare/Default)
\t@echo "==> xray 精简 v2：从 all.go 剔除 $(words $(XRAY_SLIM_MODULES)) 个模块"
\t@for m in $(XRAY_SLIM_MODULES); do \\
\t\tsed -i "\\|github.com/xtls/xray-core/$$m\\"|d" $(PKG_BUILD_DIR)/main/distro/all/all.go || exit 1; \\
\tdone
\t@n=$$(grep -c '^[[:space:]]*_ "' $(PKG_BUILD_DIR)/main/distro/all/all.go || true); \\
\t\techo "==> all.go 剩余注册行: $$n（原始 54 行）"
\t@C=$(PKG_BUILD_DIR)/main/commands/all/commands.go; \\
\tif [ -f "$$C" ]; then \\
\t\tsed -i '\\|github.com/xtls/xray-core/main/commands/all/api"|d' $$C || exit 1; \\
\t\tsed -i '/^[[:space:]]*api\\.CmdAPI,/d' $$C || exit 1; \\
\t\tif grep -q 'CmdAPI' $$C; then \\
\t\t\techo "!! 错误：api.CmdAPI 未完全移除，grpc 仍会被链接" >&2; exit 1; \\
\t\tfi; \\
\t\techo "==> 已摘除 CLI 的 api 子命令（切断 gRPC 依赖链）"; \\
\telse \\
\t\techo "!! 警告：找不到 main/commands/all/commands.go，gRPC 可能仍在" >&2; \\
\tfi
\t@echo "==> 残留 grpc 引用自检（应为空）："; \\
\tgrep -rl 'google.golang.org/grpc' $(PKG_BUILD_DIR)/app $(PKG_BUILD_DIR)/main 2>/dev/null | head -5 || true
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

    if VERSION_MARK in src:
        print("==> xray 精简 v2 补丁已存在，跳过（幂等）")
        return 0

    if LEGACY_MARK in src:
        print("!! 错误：检测到 v1 精简补丁（只删传输层 grpc，无效）。"
              "请重新拉取干净的 helloworld 源码后再打 v2。", file=sys.stderr)
        return 1

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
        nl = src.find("\n", insert_at)
        insert_at = (nl + 1) if nl >= 0 else len(src)

    block = "\n" + build_block() + "\n"
    out = src[:insert_at] + block + src[insert_at:]

    with open(path, "w", encoding="utf-8", errors="surrogateescape") as f:
        f.write(out)

    print("==> 已注入 xray 精简 v2 Build/Prepare（共 %d 个模块）" % len(DROP))
    print("    [A 组 协议/传输] %d 个" % len(DROP_TRANSPORT))
    for m in DROP_TRANSPORT:
        print("       - %s" % m)
    print("    [B 组 gRPC API 链] %d 个" % len(DROP_GRPC_API))
    for m in DROP_GRPC_API:
        print("       - %s" % m)
    print("    + 摘除 commands.go 里的 api 子命令")
    print("==> Makefile: %s (%d 行)" % (path, out.count("\n")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
