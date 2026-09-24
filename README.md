# Xray VLESS + REALITY 一键安装脚本

单脚本同时支持 **Ubuntu / Debian / CentOS**(自动识别 `apt-get` / `yum`,无需分版本),管理命令内置,不依赖任何远程管理脚本。基于 233boy/v2ray 框架改造,核心为 Xray REALITY。

| 文件 | 用途 |
|---|---|
| `install-reality.sh` | 一键安装 / 管理 Xray VLESS + REALITY |
| `check-bbr.sh` | 独立检查服务器是否开启 BBR(只读,不需要装 Xray) |

## 快速部署

在全新服务器上(Ubuntu 20.04+ / Debian 11+ / CentOS 7+,root 运行):

```bash
# 交互式(会依次询问监听端口、是否附加 HTTPS 正向代理)
bash <(curl -fsSL https://raw.githubusercontent.com/aliezencore/xray-reality-installer/main/install-reality.sh)

# 带参数(注意参数直接跟在后面)
bash <(curl -fsSL https://raw.githubusercontent.com/aliezencore/xray-reality-installer/main/install-reality.sh) --https-proxy --port 8443

# 或者先下载再执行(CentOS 最小装也可用 wget)
curl -fsSL https://raw.githubusercontent.com/aliezencore/xray-reality-installer/main/install-reality.sh -o ir.sh && bash ir.sh
wget -q https://raw.githubusercontent.com/aliezencore/xray-reality-installer/main/install-reality.sh -O ir.sh && bash ir.sh
```

> 通过管道/CI 非交互运行时,端口和 HTTPS 代理询问都会跳过(端口默认 443),需要时用 `--port` / `--https-proxy` 显式指定。

## 功能特性

- VLESS + REALITY(Vision flow),自动生成节点信息与客户端链接,保存到 `/etc/xray/info.txt`
- 兼容 Xray 新旧版本(含 26.x 的 `PrivateKey` / `Password (PublicKey)` 输出格式)
- 下载 SHA256 校验(解析官方 `.dgst`,格式宽容),失败显式告警
- 端口占用三级检测(ss / netstat / /proc)、配置生成后 `xray run -test` 自检
- **端口自定义**:交互式安装时提示输入端口(回车用默认 443),非法/被占用会重新询问,适配「商家安全组只放行部分端口」
- 自动放行防火墙(firewalld / ufw)、BBR 自动开启(sysctl.d 持久化,旧内核/容器环境明确告警而非静默失败),`xray bbr` 可随时复查
- systemd 服务:`Restart=on-failure`、文件描述符上限、沙箱加固
- **可选附加**:HTTPS 正向代理 `https://user:pass@ip:port`(自签证书 + 随机账号密码,端口可指定或随机)
- 内置管理命令 `xray`,更新采用临时文件 + 原子替换(不会 Text file busy)

## 参数

| 参数 | 说明 |
|---|---|
| `-p, --port <port>` | REALITY 监听端口(默认 443;交互式安装时未指定会提示输入) |
| `-s, --sni <domain>` | 指定伪装站点域名(默认自动探测) |
| `-n, --name <name>` | 节点名称(默认 VPS-REALITY) |
| `-v, --version <ver>` | 指定 Xray 版本,如 `v25.1.1`(默认 latest) |
| `-x, --proxy <addr>` | 下载走代理(GitHub 直连不畅的机器),如 `http://127.0.0.1:2333` |
| `--https-proxy` | 附加安装 HTTPS 正向代理(端口交互询问/随机) |
| `--https-proxy-port <p>` | 指定 HTTPS 代理端口(隐含 `--https-proxy`) |
| `-h, --help` | 帮助 |

## 端口自定义

多数 VPS 商家只在安全组里放行了少数端口(比如只开 80/443/8443),**脚本无法替你猜出哪个端口是通的**,所以:

- 交互式运行且未给 `--port` 时,脚本会提示 `请输入 REALITY 监听端口 [默认 443]`,填你**已放行**的那个即可,直接回车用 443
- 端口非法(非数字/越界)或被占用时会**重新询问**,不会直接退出
- 附加 HTTPS 代理同理:回车用随机端口,也可以填一个已放行的固定端口
- 管道 / CI 等非交互环境不提示,直接用 `--port`,未给则用默认 443
- 装完会提醒你去商家面板放行对应端口 —— 系统防火墙脚本能自动处理(firewalld/ufw),但**商家安全组只能手动放行**

```bash
bash install-reality.sh                      # 交互式:会依次询问端口 / 是否装正向代理
bash install-reality.sh --port 8443          # 非交互:直接指定主端口
bash install-reality.sh --port 8443 --https-proxy-port 3128
```


## 示例

```bash
bash install-reality.sh                                          # 交互式:提示输入端口、询问是否装代理
bash install-reality.sh --port 8443 --name 我的节点               # 自定义端口/名称
bash install-reality.sh --https-proxy --https-proxy-port 3128    # 带正向代理,固定端口
bash install-reality.sh --proxy http://127.0.0.1:2333            # GitHub 下载走代理
xray {start|stop|restart|status|info|log|loglevel|conn|config|test|bbr|update|uninstall}
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

## BBR 加速

脚本会自动写入 `/etc/sysctl.d/99-xray-bbr.conf`(`fq` + `bbr`)并立即生效。

### 最快的一条命令

```bash
[ "$(sysctl -n net.ipv4.tcp_congestion_control)" = bbr ] && echo "BBR 已开启" || echo "BBR 未开启"
```

### 完整检查脚本(不需要装 Xray 也能跑)

`check-bbr.sh` 是独立脚本,只读 `/proc/sys` 与 `/etc/sysctl.d`,不需要 root:

```bash
bash check-bbr.sh
# 或直接跑,不落地文件
bash <(curl -fsSL https://raw.githubusercontent.com/aliezencore/xray-reality-installer/main/check-bbr.sh)
```

```
BBR 状态检查  (主机: my-vps)
----------------------------------------------------------
  内核版本 : 5.15.0-91-generic
  当前算法 : bbr
  可用算法 : reno cubic bbr
  队列算法 : fq
  持久化   : /etc/sysctl.d/99-xray-bbr.conf
  连接实测 : bbr (端口 8443 上已建立连接)
----------------------------------------------------------
  => BBR 已开启
```

退出码可直接用于判断/自动化:`0` = 已开启,`1` = 未开启,`2` = 无法读取内核参数。非终端环境下自动关闭颜色。

### 装好 Xray 之后

管理命令也能查:

```bash
xray bbr
```

```
BBR 状态:
  内核版本 : 5.15.0-91-generic
  当前算法 : bbr
  可用算法 : reno cubic bbr
  队列算法 : fq
  连接实测 : bbr (端口 8443 上的已建立连接)
  => BBR 已开启
```

### 手工核对(三条)

```bash
sysctl net.ipv4.tcp_congestion_control              # 期望 = bbr
sysctl net.ipv4.tcp_available_congestion_control    # 期望包含 bbr
sysctl net.core.default_qdisc                       # 期望 = fq
```

### 判读要点

- **只有 `tcp_congestion_control` 为 `bbr` 才算真开**。`tcp_available_congestion_control` 里有 `bbr` 只说明内核支持,不代表已启用 —— 这两个最容易看混
- `net.core.default_qdisc` 建议为 `fq`:BBR 的配套队列,不带 fq 效果会打折(脚本会提醒)
- **已建立的连接不会因改 sysctl 而切换算法**,老连接仍是建连时的算法。`ss -ti` 显示的才是这条连接真正在用的(`连接实测` 取的就是它,与「当前算法」不一致属正常)
- 只看运行时值不够,**还要看持久化**:sysctl 改了但没写进 `/etc/sysctl.d/`,重启就退回默认算法(检查脚本会单独列出这一行)
- 需要内核 >= 4.9。OpenVZ/LXC 等共享宿主内核的容器里 `/proc/sys` 往往只读,宿主机不换内核就无法开启 —— 此时脚本明确告警,不会静默失败

## 后端检查与排障

这套部署**没有 `v2ray` 命令了** —— 管理命令叫 **`xray`**(核心是 Xray,REALITY 只有 Xray 支持)。

### 文件都在哪

| 路径 | 内容 |
|---|---|
| `/usr/local/bin/xray` | 管理命令(脚本) |
| `/etc/xray/config.json` | 主配置(权限 600) |
| `/etc/xray/info.txt` | 节点信息与客户端链接(权限 600) |
| `/etc/xray/bin/xray` | Xray 二进制 |
| `/etc/xray/bin/geoip.dat` `geosite.dat` | GeoIP / GeoSite 数据 |
| `/etc/xray/hp-cert.pem` `hp-key.pem` | 附加 HTTPS 代理的自签证书(装了才有) |
| `/etc/systemd/system/xray.service` | systemd 单元 |

### 日志:先注意这个坑

配置里默认 `"loglevel": "warning"`,**正常运行几乎不产生任何日志**。所以 `xray log` 看不到内容时,不要以为没连上。

```bash
xray loglevel          # 看当前级别
xray loglevel info     # 排障:改成 info 并自动重启
xray log               # 跟日志(Ctrl-C 退出)
xray loglevel warning  # 排查完改回去,免得刷爆磁盘
```

`loglevel` 改配置走的是「写临时文件 → `xray run -test` 自检 → 原子替换」,自检不过就放弃修改,不会把线上配置改坏。

### 执行情况

```bash
xray status
```

```
● xray.service - Xray Service (VLESS+REALITY)
     Active: active (running) since Thu 2026-09-24 21:00:00 UTC

--- 运行详情 ---
  启动时间 : Thu 2026-09-24 21:00:00 UTC
  重启次数 : 0
  日志级别 : warning    (改级别: xray loglevel info)
  监听端口 : 8443 (监听中)
  在线连接 : 2 条
```

`监听端口` 是单独确认的 —— `systemctl` 说 active **不等于**端口真的在监听。

```bash
xray conn     # 列出该端口上的已建立连接(含对端 IP:端口)
xray info     # 节点信息 + 客户端链接
```

### 等价的原始命令

不想记管理命令时,直接:

```bash
systemctl status xray                    # 服务状态
journalctl -u xray -n 100 --no-pager     # 最近 100 行日志
journalctl -u xray -f                    # 实时跟踪
journalctl -u xray --since "10 min ago"  # 按时间过滤
/etc/xray/bin/xray run -test -config /etc/xray/config.json   # 校验配置
jq . /etc/xray/config.json               # 格式化看配置
```

### 常见问题速查

| 现象 | 先看 |
|---|---|
| 客户端连不上 | `xray status` 确认端口在监听 → `xray loglevel info` + `xray log` |
| 服务起不来 / 反复重启 | `journalctl -u xray -n 50`;SELinux 的 203/EXEC 见安装脚本注释 |
| 日志里什么都没有 | 正常,`warning` 级别就是如此,改成 `info` |
| 速度慢 | `xray bbr` 确认 BBR,再看 VPS 带宽与线路 |
| 改了配置没生效 | `xray test` 校验 + `xray restart` |

## 其他

- 需要 root;端口被占用时交互模式会重新询问,非交互模式报错并提示改用 `--port`
- 装完请确认商家安全组已放行对应 TCP 端口(系统防火墙脚本会自动处理,安全组只能手动放行)
- 卸载:`xray uninstall`(服务、配置、证书、管理命令一并清理)
- 仓库仅含脚本,无任何密钥/配置数据
