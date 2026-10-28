# Hysteria2 一键安装脚本

单脚本在 **Ubuntu / Debian / CentOS / Rocky / Alpine(systemd)** 上完成 Hysteria2 服务端部署:自举下载二进制、自签证书、生成配置、systemd 常驻、放行防火墙、开 BBR、输出客户端链接。

移植自 `app_hysteria2.py` 的部署逻辑(二进制自举 + SHA256 校验 + `hysteria cert` 自签 + 配置试启动自检),去掉容器平台特有的部分,换成更适合 VPS 的形态。

## 快速部署

root 用户在全新服务器上执行:

```bash
# 一行装完(全默认: UDP/443 + 自签证书 + 随机密码)
bash <(curl -fsSL https://raw.githubusercontent.com/aliezencore/xray-reality-installer/main/install-hysteria2.sh)

# 已下载脚本时
bash install-hysteria2.sh

# 自定义端口 / SNI / 节点名
bash install-hysteria2.sh --port 8443 --sni www.apple.com --name 我的HY2

# GitHub 直连不畅(下载慢或超时)时走本地代理
bash install-hysteria2.sh --proxy http://127.0.0.1:2333
```

脚本全程不提问(适合非交互/CI 环境),想要什么都用参数给定。

装完后:

```bash
hy2 info      # 节点信息 + 客户端链接
hy2 qr        # 直接出二维码(需 qrencode)
```

> 脚本默认下载 `HyNetworks/hysteria`(原 `apernet/hysteria`,已迁移)的 `app/v2.13.0`,与 `app_hysteria2.py` 的默认版本一致;`--version latest` 可装最新版。

## 参数

| 参数 | 说明 |
|---|---|
| `-p, --port <端口>` | UDP 监听端口(默认 443) |
| `-s, --sni <域名>` | 证书 CN/SAN 与客户端 SNI(默认 `www.bing.com`) |
| `-n, --name <名称>` | 客户端里的节点显示名(默认 `HY2-<公网IP>`) |
| `-P, --password <密码>` | 认证密码(默认随机 32 字符;重装默认沿用旧密码) |
| `--obfs` | 启用 salamander 混淆(默认关闭) |
| `--obfs-password <密码>` | 指定混淆密码(隐含 `--obfs`) |
| `-m, --masquerade <URL>` | 伪装反代目标(默认 `https://www.bing.com`;填 `none` 关闭) |
| `-v, --version <tag>` | 版本 tag,如 `app/v2.13.0`,或 `latest` |
| `-c/--cert`,`-k/--key` | 使用自己的证书(不再生成自签证书) |
| `-x, --proxy <代理>` | 下载走代理 |
| `--no-bbr` / `--no-firewall` | 不动 BBR / 不动防火墙 |
| `--force` | 强制重新下载二进制 |
| `--regen` | 重新生成密码与证书(旧链接立即失效,端口/SNI/混淆开关保留) |
| `--dry-run` | 只生成文件并自检,不安装服务、不改系统(需配合 `HY2_HOME`) |
| `-h, --help` | 帮助 |

## 装了些什么

| 路径 | 内容 |
|---|---|
| `/etc/hysteria2/hysteria` | hysteria 二进制(release 资产,优先按 `hashes.txt` 校验 SHA256) |
| `/etc/hysteria2/config.yaml` | 服务端配置(权限 600) |
| `/etc/hysteria2/cert.pem` `/etc/hysteria2/key.pem` | 自签证书(10 年,`hysteria cert` 生成) |
| `/etc/hysteria2/node.conf` | 节点元数据(密码/SNI/pinSHA256/链接),重装与 `hy2 info` 用 |
| `/etc/hysteria2/info.txt` | 人读的节点信息 |
| `/etc/systemd/system/hysteria2.service` | systemd 服务(`Restart=always` + 基础沙箱加固) |
| `/usr/local/bin/hy2` | 管理命令 |
| `/etc/sysctl.d/99-hysteria2-bbr.conf` | BBR + fq 持久化 |

管理命令:

```bash
hy2 {start|stop|restart|status}   服务控制
hy2 info | link | qr              节点信息 / 链接 / 二维码
hy2 log [行数]                    日志(journalctl)
hy2 config [edit]                 查看/编辑配置(edit 后自动重启)
hy2 test                          校验当前配置能否被 hysteria 接受
hy2 update [tag]                  更新二进制,保留配置
hy2 regen                         重置密码与证书
hy2 uninstall                     卸载
```

## 连不上?先查 UDP

Hysteria2 **只有 UDP,没有 TCP 回退**。如果日志一切正常但客户端连不上,99% 是 UDP 没放行,而且不会有任何报错:

1. 云厂商安全组 / 网络 ACL 放行 **UDP 端口**(很多人只放行了 TCP)
2. 本机防火墙:`ufw status` / `firewall-cmd --list-all`
3. 命令行验证(在**你自己的电脑**上跑,不是服务器上):

```bash
python -c "import socket;s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM);s.settimeout(5);s.sendto(b'ping',('<服务器IP>',443));print(s.recvfrom(64))"
```

注意:这条命令能通只代表 UDP 路径通,不代表 Hysteria2 正常(服务端不会回 `ping`);超时则基本可以断定 UDP 被封。更严谨的做法是直接用客户端连一次,看服务端 `hy2 log` 里有没有 `client connected`。

## 客户端

链接形如:

```
hysteria2://<密码>@<IP>:<端口>/?sni=www.bing.com&insecure=1&pinSHA256=<证书哈希>#HY2-<IP>
```

导入 v2rayN / NekoBox / sing-box / Shadowrocket / Clash.Meta 即可。自签证书 + `insecure=1` 时,`pinSHA256` 仍然把 MITM 风险压回去,不要删。

客户端里值得调的参数:

- `up` / `down`:带宽(如 `50 mbps` / `200 mbps`),声明后 BBR 才能按实际带宽收敛,填小了会压速
- `--obfs` 只有服务端也开启时才需要(客户端填同款 salamander 密码)
- 端口跳跃(`mport`)需要额外加 iptables/nft 规则,本脚本不涉及

## 与 `app_hysteria2.py` 的差异

`app_hysteria2.py` 是给 KataBump 这类**容器平台**用的:它靠 `SERVER_PORT`/`SERVER_IP` 环境变量运行,把 TCP 面板和 UDP 代理挤在同一个端口号上,自己当 hysteria 的守护进程。

本脚本面向**独立 VPS**,因此:

- 去掉 MyBox Web 面板(TCP)与同端口号复用逻辑 —— VPS 不需要,也不该多开一个 HTTP 面
- 守护交给 systemd(`Restart=always`),不再自己写 asyncio 重启循环
- 补上 VPS 才需要的部分:防火墙放行、BBR、开机自启、下载加速镜像、`hy2` 管理命令
- 保留原脚本的关键经验:release 裸二进制 + `hashes.txt` SHA256 校验、`hysteria cert` 自签(不依赖 openssl)、
  `pinSHA256` 用十六进制而非 base64、配置先试启动再落盘、URI query 用 `quote` 而非 `quote_plus`

容器/无 systemd 环境请继续用 `app_hysteria2.py`(本脚本检测不到 systemd 会直接拒绝安装)。

## 其他

- 需要 root;端口 <1024 时 systemd 已给 `CAP_NET_BIND_SERVICE`
- 卸载:`hy2 uninstall`(防火墙规则与 BBR 的 sysctl 文件不自动回收)
- 升级:`hy2 update`(临时文件 + 原子替换,不会 Text file busy)
- 想换端口/SNI:重跑安装脚本并带对应参数即可,密码与证书会保留
