# Xray VLESS + REALITY 一键安装脚本

单脚本同时支持 **Ubuntu / Debian / CentOS**(自动识别 `apt-get` / `yum`,无需分版本),管理命令内置,不依赖任何远程管理脚本。基于 233boy/v2ray 框架改造,核心为 Xray REALITY。

## 快速部署

在全新服务器上(Ubuntu 20.04+ / Debian 11+ / CentOS 7+,root 运行):

```bash
# 交互式(会询问是否附加 HTTPS 正向代理)
bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/xray-reality-installer/main/install-reality.sh)

# 带参数(注意参数直接跟在后面)
bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/xray-reality-installer/main/install-reality.sh) --https-proxy --port 8443

# 或者先下载再执行(CentOS 最小装也可用 wget)
curl -fsSL https://raw.githubusercontent.com/<你的用户名>/xray-reality-installer/main/install-reality.sh -o ir.sh && bash ir.sh
wget -q https://raw.githubusercontent.com/<你的用户名>/xray-reality-installer/main/install-reality.sh -O ir.sh && bash ir.sh
```

> 通过管道/CI 非交互运行时,HTTPS 代理询问会自动跳过,需要时加 `--https-proxy` 参数。

## 功能特性

- VLESS + REALITY(Vision flow),自动生成节点信息与客户端链接,保存到 `/etc/xray/info.txt`
- 兼容 Xray 新旧版本(含 26.x 的 `PrivateKey` / `Password (PublicKey)` 输出格式)
- 下载 SHA256 校验(解析官方 `.dgst`,格式宽容),失败显式告警
- 端口占用三级检测(ss / netstat / /proc)、配置生成后 `xray run -test` 自检
- 自动放行防火墙(firewalld / ufw)、BBR 自动开启(sysctl.d 持久化,旧内核仅告警)
- systemd 服务:`Restart=on-failure`、文件描述符上限、沙箱加固
- **可选附加**:HTTPS 正向代理 `https://user:pass@ip:port`(自签证书 + 随机账号密码 + 随机端口)
- 内置管理命令 `xray`,更新采用临时文件 + 原子替换(不会 Text file busy)

## 参数

| 参数 | 说明 |
|---|---|
| `-p, --port <port>` | REALITY 监听端口(默认 443) |
| `-s, --sni <domain>` | 指定伪装站点域名(默认自动探测) |
| `-n, --name <name>` | 节点名称(默认 VPS-REALITY) |
| `-v, --version <ver>` | 指定 Xray 版本,如 `v25.1.1`(默认 latest) |
| `-x, --proxy <addr>` | 下载走代理(GitHub 直连不畅的机器),如 `http://127.0.0.1:2333` |
| `--https-proxy` | 附加安装 HTTPS 正向代理(端口随机) |
| `--https-proxy-port <p>` | 指定 HTTPS 代理端口(隐含 `--https-proxy`) |
| `-h, --help` | 帮助 |

## 示例

```bash
bash install-reality.sh                                          # 全默认
bash install-reality.sh --port 8443 --name 我的节点               # 自定义端口/名称
bash install-reality.sh --https-proxy --https-proxy-port 3128    # 带正向代理,固定端口
bash install-reality.sh --proxy http://127.0.0.1:2333            # GitHub 下载走代理
xray {start|stop|restart|status|info|log|config|test|update|uninstall}
```

## SNI 伪装站点策略

默认候选按「大厂但低调的境外站优先」排序:Samsung / AMD / Sony / Tesla / Intel / Mozilla / Cici(豆包海外) / Coze / Apple / Amazon / IBM / NVIDIA / dl.google,最后才是 Microsoft 兜底。每个候选实测 TLS1.3 + h2 + 非 Cloudflare。

- **自动跳过套 Cloudflare 的站点**:用 CF 站做 REALITY 回落会被"打野"扫描并举报商家封机(社区案例:DMIT 封机,参考 linux.do/t/topic/2854265)
- `--sni` 手动指定 CF 站时会明确警告
- 最稳妥做法:使用自己注册的域名(CF 只做 DNS 解析、不开橙云也可)

## HTTPS 正向代理说明

- 地址形如 `https://<user>:<pass>@<ip>:<port>`,账号密码随机生成,见 `info.txt`
- 证书为自签(SAN 绑定服务器 IP),客户端需忽略代理证书校验:
  `curl -x https://user:pass@ip:port --proxy-insecure https://www.google.com`(Python requests 用 `verify=False`)
- 必须带账号密码,防止被扫成开放代理

## 其他

- 需要 root;443 被占用时脚本会提示改用 `--port`
- 卸载:`xray uninstall`(服务、配置、证书、管理命令一并清理)
- 仓库仅含本脚本,无任何密钥/配置数据
