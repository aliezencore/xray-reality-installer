#!/bin/bash
#
# Hysteria2 一键安装脚本 (Linux + systemd)
#
# 由 C:\workspace\app_hysteria2.py 的逻辑移植而来: 保留那份"自举 + 自检"的思路,
# 去掉容器平台的产物(Web 面板 / 单端口 TCP 复用), 换成更适合 VPS 的形态:
#   - hysteria 官方 release 二进制自举安装, 优先按 hashes.txt 做 SHA256 校验
#   - 自签证书由 `hysteria cert` 生成(不需要 openssl), 并直接取它输出的 pinSHA256
#   - 配置写好后先在随机空闲 UDP 端口上试启动校验, 通过后才落盘/重启服务
#   - systemd 服务常驻 + 基础沙箱加固, 开机自启
#   - 自动放行 UDP 端口(ufw / firewalld / iptables)并开启 BBR
#   - 生成 hysteria2:// 客户端链接, 落盘到 info.txt, 有 qrencode 时直接出二维码
#   - 内置管理命令 hy2 {start|stop|restart|status|info|link|qr|log|config|test|update|regen|uninstall}
#
# 用法:
#   bash install-hysteria2.sh                                  # 默认 UDP/443, 自签证书, 随机密码
#   bash install-hysteria2.sh --port 8443 --sni www.apple.com   # 自定义端口与伪装 SNI
#   bash install-hysteria2.sh --obfs                            # 额外启用 salamander 混淆
#   bash install-hysteria2.sh --proxy http://127.0.0.1:2333     # GitHub 直连不畅时走代理下载
#
# 注意: Hysteria2 只跑 UDP, 平台/安全组必须放行 UDP, 没有 TCP 回退。

# ---------------------------------------------------------------------------
# 颜色与输出 (沿用 install-reality.sh 风格)
# ---------------------------------------------------------------------------
red='\e[31m'
yellow='\e[33m'
gray='\e[90m'
green='\e[92m'
blue='\e[94m'
magenta='\e[95m'
cyan='\e[96m'
none='\e[0m'
_red() { echo -e "${red}$*${none}"; }
_blue() { echo -e "${blue}$*${none}"; }
_cyan() { echo -e "${cyan}$*${none}"; }
_green() { echo -e "${green}$*${none}"; }
_yellow() { echo -e "${yellow}$*${none}"; }
_magenta() { echo -e "${magenta}$*${none}"; }
_red_bg() { echo -e "\e[41m$*${none}"; }

is_err=$(_red_bg 错误!)
is_warn=$(_red_bg 警告!)

err() {
    echo -e "\n$is_err $*\n" && exit 1
}

warn() {
    echo -e "\n$is_warn $*\n"
}

# 用法: msg "文本"  或  msg ok|warn|err "文本"
msg() {
    local color=$blue text=$1
    case $1 in
    warn) color=$yellow; text=$2 ;;
    err) color=$red; text=$2 ;;
    ok) color=$green; text=$2 ;;
    esac
    echo -e "${color}$(date +'%T')${none}) ${text}"
}

# ---------------------------------------------------------------------------
# 默认参数
# ---------------------------------------------------------------------------
HY2_HOME=${HY2_HOME:-/etc/hysteria2}
HY2_HOME=${HY2_HOME%/}

hy2_repo=${HY2_REPO:-HyNetworks/hysteria}   # 与 app_hysteria2.py 一致(apernet/hysteria 已迁移到此仓库)
hy2_version=${HY2_VERSION:-app/v2.13.0}     # 与 app_hysteria2.py 的 DEFAULT_VERSION 对齐
port=443
sni=www.bing.com
node_name=
password=
obfs_password=
obfs=
masquerade=https://www.bing.com
user_cert=
user_key=
proxy=
bbr=1
fw=1
dry_run=0
force=0
regen=0

port_set=0
sni_set=0
name_set=0

# 下载加速前缀; 直连 GitHub 失败时依次尝试(每个候选都会重试)
mirrors=(
    ""
    "https://ghfast.top/"
    "https://gh-proxy.com/"
    "https://ghproxy.net/"
)

bin_file=$HY2_HOME/hysteria
conf_file=$HY2_HOME/config.yaml
cert_file=$HY2_HOME/cert.pem
key_file=$HY2_HOME/key.pem
meta_file=$HY2_HOME/node.conf
info_file=$HY2_HOME/info.txt
link_file=$HY2_HOME/client-link.txt
service_name=hysteria2
service_file=/etc/systemd/system/$service_name.service
cmd_file=/usr/local/bin/hy2
bbr_conf=/etc/sysctl.d/99-hysteria2-bbr.conf

# ---------------------------------------------------------------------------
# 帮助
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
Hysteria2 一键安装脚本 (Linux + systemd, 需要 root)

用法: bash install-hysteria2.sh [选项]

  -p, --port <端口>          UDP 监听端口 (默认 443)
  -s, --sni <域名>           证书 CN / 客户端 SNI (默认 www.bing.com)
  -n, --name <名称>          客户端里的节点显示名 (默认 HY2-<公网IP>)
  -P, --password <密码>      认证密码 (默认随机生成; 重装时默认沿用旧密码)
      --obfs                 启用 salamander 混淆 (默认关闭, 密码随机)
      --obfs-password <密码> 指定混淆密码 (隐含 --obfs)
  -m, --masquerade <URL>     伪装反代目标 (默认 https://www.bing.com; 填 none 关闭)
  -v, --version <tag>        hysteria 版本 tag, 如 app/v2.13.0, 或 latest
  -c, --cert <路径>          使用已有证书 (需同时给 --key)
  -k, --key <路径>           使用已有私钥
  -x, --proxy <代理>         下载走代理, 如 http://127.0.0.1:2333
      --no-bbr               不自动开启 BBR
      --no-firewall          不自动放行防火墙
      --force                强制重新下载二进制
      --regen                重新生成密码与自签证书 (旧链接立即失效)
      --dry-run              只在 HY2_HOME 下生成文件并自检, 不装服务/不改系统
  -h, --help                 显示本帮助

示例:
  bash install-hysteria2.sh
  bash install-hysteria2.sh --port 8443 --sni www.apple.com --obfs
  bash install-hysteria2.sh --version latest --proxy http://127.0.0.1:2333

装完后管理: hy2 {start|stop|restart|status|info|link|qr|log|config|test|update|regen|uninstall}
EOF
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case $1 in
    -p | --port) port=${2:-}; port_set=1; shift 2 ;;
    -s | --sni) sni=${2:-}; sni_set=1; shift 2 ;;
    -n | --name) node_name=${2:-}; name_set=1; shift 2 ;;
    -P | --password) password=${2:-}; shift 2 ;;
    --obfs) obfs=1; shift ;;
    --obfs-password) obfs_password=${2:-}; obfs=1; shift 2 ;;
    -m | --masquerade) masquerade=${2:-}; shift 2 ;;
    -v | --version) hy2_version=${2:-}; shift 2 ;;
    -c | --cert) user_cert=${2:-}; shift 2 ;;
    -k | --key) user_key=${2:-}; shift 2 ;;
    -x | --proxy) proxy=${2:-}; shift 2 ;;
    --no-bbr) bbr=0; shift ;;
    --no-firewall) fw=0; shift ;;
    --force) force=1; shift ;;
    --regen) regen=1; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --port=* | --sni=* | --name=* | --password=* | --obfs-password=* | --masquerade=* | --version=* | --cert=* | --key=* | --proxy=*)
        # 兼容 --opt=value 写法
        __opt=${1%%=*}
        __val=${1#*=}
        shift
        set -- "$__opt" "$__val" "$@"
        ;;
    *)
        err "未知参数: $1 (用 --help 查看用法)"
        ;;
    esac
done

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
# 小文件抓取: 输出到 stdout。
# 仅在设置了 --proxy 时才给 https_proxy, 否则部分 wget 会把空值当成"本机代理"
fetch_text() {
    local url=$1
    if [[ $proxy ]]; then
        if type -P curl >/dev/null; then
            https_proxy=$proxy curl -fsSL --connect-timeout 15 --retry 2 --retry-delay 2 "$url"
        else
            https_proxy=$proxy wget --no-check-certificate -q -T 20 -t 2 -O - "$url"
        fi
    else
        if type -P curl >/dev/null; then
            curl -fsSL --connect-timeout 15 --retry 2 --retry-delay 2 "$url"
        else
            wget --no-check-certificate -q -T 20 -t 2 -O - "$url"
        fi
    fi
}

# 依次尝试直连与镜像抓取小文件(hashes.txt 这类)
fetch_text_mirrored() {
    local url=$1 prefix txt
    for prefix in "${mirrors[@]}"; do
        txt=$(fetch_text "${prefix}${url}" 2>/dev/null) && [[ -n $txt ]] && {
            printf '%s\n' "$txt"
            return 0
        }
    done
    return 1
}

_download_once() { # url dest
    local url=$1 dest=$2 rc pb
    # 进度条只在交互终端显示; 被重定向/CI 抓取时保持安静, 免得日志里刷几千行
    pb=
    if [[ -t 2 ]] && type -P curl >/dev/null; then
        pb=--progress-bar
    fi
    if type -P curl >/dev/null; then
        if [[ $proxy ]]; then
            https_proxy=$proxy curl -fL $pb --connect-timeout 15 --retry 2 --retry-delay 2 -o "$dest" "$url"
        else
            curl -fL $pb --connect-timeout 15 --retry 2 --retry-delay 2 -o "$dest" "$url"
        fi
        rc=$?
    else
        if [[ $proxy ]]; then
            https_proxy=$proxy wget --no-check-certificate -T 20 -t 2 -O "$dest" "$url"
        else
            wget --no-check-certificate -T 20 -t 2 -O "$dest" "$url"
        fi
        rc=$?
    fi
    [[ $rc == 0 && -s $dest ]]
}

download_file() { # url dest -> 依次尝试直连与镜像
    local url=$1 dest=$2 part=$2.part prefix
    for prefix in "${mirrors[@]}"; do
        rm -f "$part"
        if [[ -n $prefix ]]; then
            msg "下载(镜像 $prefix) > $url"
        else
            msg "下载 > $url"
        fi
        if _download_once "${prefix}${url}" "$part"; then
            mv -f "$part" "$dest"
            return 0
        fi
        rm -f "$part"
    done
    return 1
}

sha256_file() { # file -> hex (拿不到算法时输出空)
    if type -P sha256sum >/dev/null; then
        sha256sum "$1" 2>/dev/null | awk '{print $1}'
    elif type -P shasum >/dev/null; then
        shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
    elif type -P openssl >/dev/null; then
        openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
    fi
}

# 公网 IPv4: 多源直连(不走 --proxy, 否则拿到的是代理出口 IP)
get_ip() {
    local ip
    if type -P curl >/dev/null; then
        ip=$(https_proxy= curl -4 -fsS --connect-timeout 5 -m 8 https://one.one.one.one/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}')
        [[ -z $ip ]] && ip=$(https_proxy= curl -4 -fsS --connect-timeout 5 -m 8 https://api.ipify.org 2>/dev/null)
        [[ -z $ip ]] && ip=$(https_proxy= curl -4 -fsS --connect-timeout 5 -m 8 https://ipinfo.io/ip 2>/dev/null)
    else
        ip=$(https_proxy= wget -4 -q -T 8 -t 1 -O - https://one.one.one.one/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2; exit}')
        [[ -z $ip ]] && ip=$(https_proxy= wget -4 -q -T 8 -t 1 -O - https://api.ipify.org 2>/dev/null)
        [[ -z $ip ]] && ip=$(https_proxy= wget -4 -q -T 8 -t 1 -O - https://ipinfo.io/ip 2>/dev/null)
    fi
    echo "$ip" | tr -d ' \t\r\n'
}

# 百分号编码(python3 优先; 无 python3 时按字节处理, 支持 UTF-8 节点名)
urlencode() {
    if type -P python3 >/dev/null; then
        python3 -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
        return
    fi
    printf '%s' "$1" | od -An -v -tu1 | awk '{
        for (i = 1; i <= NF; i++) {
            b = $i
            if ((b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 45 || b == 46 || b == 95 || b == 126)
                printf "%c", b
            else
                printf "%%%02X", b
        }
    }'
}

# 放进 YAML 双引号标量的安全字符串
yamlq() {
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

rand_password() {
    # 与 python secrets.token_urlsafe 同风格的 URL 安全随机串(无 +/= 等需要转义的字符)
    if type -P openssl >/dev/null; then
        openssl rand -base64 48 2>/dev/null | tr -d '\n=' | tr '+/' '-_' | cut -c1-32
    else
        head -c 48 /dev/urandom | base64 | tr -d '\n=' | tr '+/' '-_' | cut -c1-32
    fi
}

meta_get() { # KEY -> 值 (node.conf 是 KEY=VALUE 逐行格式, 值不经过 shell 解析)
    [[ -f $meta_file ]] || return 0
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$meta_file"
}

meta_set() { # KEY VALUE  (写入/覆盖一行)
    local k=$1 v=$2 tmp
    mkdir -p "$HY2_HOME"
    tmp=$(mktemp "$HY2_HOME/.node.conf.XXXXXX") || return 1
    if [[ -f $meta_file ]]; then
        awk -F= -v k="$k" '$1 != k' "$meta_file" >"$tmp"
    fi
    printf '%s=%s\n' "$k" "$v" >>"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$meta_file"
}

udp_port_in_use() { # port
    if type -P ss >/dev/null; then
        ss -lun 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
    elif type -P netstat >/dev/null; then
        netstat -lun 2>/dev/null | grep -qE "[:.]$1[[:space:]]"
    else
        grep -qiE ":$1[[:space:]]" /proc/net/udp /proc/net/udp6 2>/dev/null
    fi
}

pick_temp_udp_port() {
    local i p
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        p=$((20000 + RANDOM % 40000))
        udp_port_in_use "$p" || {
            echo "$p"
            return 0
        }
    done
    echo $((20000 + RANDOM % 40000))
}

# ---------------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------------
check_env() {
    [[ $(uname -s) == Linux ]] || err "此脚本仅支持 Linux"

    # 防 CRLF: 被 Windows 换行符污染时 heredoc 会写坏 systemd unit
    if [[ -f $0 ]] && grep -q $'\r' "$0" 2>/dev/null; then
        err "脚本包含 Windows 换行符(CRLF), 先执行: ${green}sed -i 's/\r\$//' $0${none} 再重新运行"
    fi

    if [[ $dry_run == 1 ]]; then
        [[ $HY2_HOME == /etc/hysteria2 ]] && err "--dry-run 请配合 HY2_HOME 使用, 例如: HY2_HOME=/tmp/hy2-test bash $0 --dry-run"
    else
        [[ $EUID == 0 ]] || err "当前非 ${yellow}ROOT${none} 用户, 请用: ${green}sudo bash $0${none}"
        type -P systemctl >/dev/null || err "缺少 ${yellow}systemctl${none}, 本脚本需要 systemd"
        [[ -d /run/systemd/system ]] || err "systemd 似乎没有运行(wsl/容器?), 请改用 systemd 环境或参考 app_hysteria2.py 的容器模式"
    fi

    type -P curl >/dev/null || type -P wget >/dev/null || err "需要 ${yellow}curl${none} 或 ${yellow}wget${none}"

    case $(uname -m) in
    x86_64 | amd64) hy_arch=amd64 ;;
    aarch64 | arm64) hy_arch=arm64 ;;
    armv8l) hy_arch=arm64 ;;
    armv7l | armv7) hy_arch=arm ;;
    armv6l) hy_arch=armv5 ;;
    i386 | i686) hy_arch=386 ;;
    riscv64) hy_arch=riscv64 ;;
    loongarch64) hy_arch=loong64 ;;
    s390x) hy_arch=s390x ;;
    *) err "暂不支持的架构: $(uname -m)" ;;
    esac
    hy_asset="hysteria-linux-$hy_arch"
}

# ---------------------------------------------------------------------------
# 二进制安装: release 提供的是裸二进制(不是 tar.gz)
# ---------------------------------------------------------------------------
release_url() { echo "https://github.com/$hy2_repo/releases/download/$hy2_version"; }

binary_ok() {
    [[ -x $bin_file ]] && "$bin_file" version 2>/dev/null | grep -q 'Version:'
}

resolve_latest_version() {
    local api tag
    api="https://api.github.com/repos/$hy2_repo/releases/latest"
    tag=$(fetch_text "$api" 2>/dev/null | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 | sed -e 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//' -e 's/"$//')
    [[ $tag ]] || return 1
    echo "$tag"
}

# 从 hashes.txt 取本机资产的 SHA256。注意新版格式是 "<hex>  build/<asset>",
# 老版可能是裸文件名或带 * 前缀的 sha256sum 风格, 这里都兼容。
release_sha256() {
    local txt
    txt=$(fetch_text_mirrored "$(release_url)/hashes.txt") || return 1
    printf '%s\n' "$txt" | awk -v want="$hy_asset" '
        {
            h = $1
            sub(/^\*/, "", h)
            n = $NF
            sub(/^.*\//, "", n)
            if (n == want && length(h) == 64 && h ~ /^[0-9a-fA-F]+$/) {
                print tolower(h)
                exit
            }
        }'
}

install_binary() {
    if [[ $force != 1 ]] && binary_ok; then
        if [[ -f $meta_file && $(meta_get VERSION) == "$hy2_version" ]]; then
            msg ok "hysteria $hy2_version 已安装, 跳过下载"
            return 0
        fi
        if [[ ! -f $meta_file ]]; then
            msg ok "检测到可用的 hysteria 二进制, 跳过下载"
            return 0
        fi
    fi

    mkdir -p "$HY2_HOME" || err "无法创建 $HY2_HOME"
    chmod 700 "$HY2_HOME"
    local url part expected actual
    url="$(release_url)/$hy_asset"
    part=$HY2_HOME/.hysteria.download

    msg "安装 hysteria $hy2_version ($hy_asset)"
    expected=$(release_sha256)
    if [[ -z $expected ]]; then
        warn "无法获取 hashes.txt 或其中没有 $hy_asset, 跳过 SHA256 校验(随后改用二进制自检)"
    fi

    download_file "$url" "$part" || {
        rm -f "$part"
        err "下载 hysteria 二进制失败。直连 GitHub 不通时可加 ${green}--proxy http://127.0.0.1:2333${none} 或 ${green}--version${none} 指定其它版本"
    }

    if [[ -n $expected ]]; then
        actual=$(sha256_file "$part")
        if [[ -z $actual ]]; then
            warn "系统缺少 sha256sum/shasum/openssl, 无法校验, 依赖随后的二进制自检"
        elif [[ $actual != "$expected" ]]; then
            rm -f "$part"
            err "SHA256 校验失败: 期望 $expected 实际 $actual (下载被劫持或版本不匹配)"
        else
            msg ok "SHA256 校验通过"
        fi
    fi

    chmod 755 "$part"
    mv -f "$part" "$bin_file"
    binary_ok || {
        rm -f "$bin_file"
        err "该二进制在本机无法执行(架构不匹配或依赖缺失)"
    }
}

# ---------------------------------------------------------------------------
# 证书: 优先 hysteria 自带的 cert 子命令(自带 pinSHA256 输出), 退路才是 openssl
# ---------------------------------------------------------------------------
pin_from_cert() { # cert.pem -> DER 的 sha256 十六进制, 即 hysteria 的 pinSHA256
    [[ -f $1 ]] || return 1
    type -P openssl >/dev/null || return 1
    openssl x509 -in "$1" -outform der 2>/dev/null | sha256sum 2>/dev/null | awk '{print $1}'
}

ensure_cert() {
    pin_sha256=
    local out

    if [[ -n $user_cert || -n $user_key ]]; then
        [[ -n $user_cert && -n $user_key ]] || err "--cert 与 --key 必须同时指定"
        [[ -f $user_cert && -f $user_key ]] || err "指定的证书或私钥文件不存在: $user_cert / $user_key"
        cfg_cert=$(readlink -f "$user_cert" 2>/dev/null || echo "$user_cert")
        cfg_key=$(readlink -f "$user_key" 2>/dev/null || echo "$user_key")
        pin_sha256=$(pin_from_cert "$cfg_cert")
        [[ -n $pin_sha256 ]] || warn "无法计算 pinSHA256(缺少 openssl), 链接将不带 pinSHA256, 客户端需放宽校验"
        msg ok "使用已有证书: $cfg_cert"
        return 0
    fi

    cfg_cert=$cert_file
    cfg_key=$key_file

    if [[ $regen == 1 ]]; then
        msg warn "重新生成密码与证书(旧链接将失效)"
        rm -f "$cert_file" "$key_file"
    fi

    if [[ -f $cert_file && -f $key_file ]]; then
        pin_sha256=$(pin_from_cert "$cert_file")
        if [[ -n $pin_sha256 ]]; then
            msg ok "复用已有证书: $cert_file"
            return 0
        fi
        warn "已有证书无法解析(缺 openssl?), 重新生成"
        rm -f "$cert_file" "$key_file"
    fi

    msg "生成自签证书 (CN/SAN=$sni, 有效期 10 年)"
    out=$("$bin_file" cert --host "$sni" --cert "$cert_file" --key "$key_file" --valid-for 87600h --overwrite 2>&1)
    local rc=$?
    if [[ $rc == 0 && -f $cert_file && -f $key_file ]]; then
        # cert 子命令会直接打印 pinSHA256, 比再算一遍更省事
        pin_sha256=$(printf '%s\n' "$out" | awk -F': *' '/pinSHA256/{print $NF; exit}' | tr -d ' \r')
        [[ -n $pin_sha256 ]] || pin_sha256=$(pin_from_cert "$cert_file")
        chmod 644 "$cert_file"
        chmod 600 "$key_file"
        [[ -n $pin_sha256 ]] || err "证书已生成, 但无法得到 pinSHA256(缺少 openssl), 请手动执行: openssl x509 -in $cert_file -outform der | sha256sum"
        msg ok "证书已生成 (pinSHA256=${pin_sha256:0:16}...)"
        return 0
    fi

    warn "hysteria cert 失败: $out"
    if ! type -P openssl >/dev/null; then
        err "无法生成证书: hysteria cert 失败且系统没有 openssl。可用 --cert/--key 指定已有证书"
    fi
    msg "改用 openssl 生成自签证书"
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
        -keyout "$key_file" -out "$cert_file" -subj "/CN=$sni" \
        -addext "subjectAltName=DNS:$sni" >/dev/null 2>&1 || err "openssl 生成证书失败"
    chmod 644 "$cert_file"
    chmod 600 "$key_file"
    pin_sha256=$(pin_from_cert "$cert_file")
    [[ -n $pin_sha256 ]] || err "无法计算 pinSHA256"
    msg ok "证书已生成 (openssl)"
}

# ---------------------------------------------------------------------------
# 配置生成: 与 app_hysteria2.py 的 render_config 保持一致
# ---------------------------------------------------------------------------
render_config() {
    local nl=$'\n' out tmp
    out="# 由 install-hysteria2.sh 生成, hy2 重启不会覆盖; 需要改结构请重跑安装脚本${nl}"
    out+="listen: :$port${nl}${nl}"
    out+="tls:${nl}"
    out+="  cert: $(yamlq "$cfg_cert")${nl}"
    out+="  key: $(yamlq "$cfg_key")${nl}"
    out+="  sniGuard: disable${nl}${nl}"
    out+="auth:${nl}"
    out+="  type: password${nl}"
    out+="  password: $(yamlq "$password")${nl}"

    if [[ -n $obfs_password ]]; then
        out+="${nl}obfs:${nl}"
        out+="  type: salamander${nl}"
        out+="  salamander:${nl}"
        out+="    password: $(yamlq "$obfs_password")${nl}"
    fi

    if [[ $masquerade != none ]]; then
        out+="${nl}masquerade:${nl}"
        out+="  type: proxy${nl}"
        out+="  proxy:${nl}"
        out+="    url: $(yamlq "$masquerade")${nl}"
        out+="    rewriteHost: true${nl}"
    fi

    out+="${nl}# 自用场景: 服务端不设 bandwidth, 由客户端自己声明(官方推荐)${nl}"
    out+="congestion:${nl}"
    out+="  type: bbr${nl}"
    out+="  bbrProfile: standard${nl}${nl}"
    out+="quic:${nl}"
    out+="  maxIdleTimeout: 30s${nl}"
    out+="  maxIncomingStreams: 1024${nl}"

    tmp=$(mktemp "$HY2_HOME/.config.XXXXXX") || err "无法写入 $HY2_HOME"
    printf '%s\n' "$out" >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$conf_file"
}

# 配置自检: hysteria 没有 `check` 子命令, 只能在随机空闲 UDP 端口上试启动一次。
# 注意不能直接用正式端口, 否则升级/重装时会被"正在运行"的旧服务占用而误报失败。
validate_config() {
    local tmp_dir tmp_conf trial_port log_file pid rc i alive=0

    trial_port=$(pick_temp_udp_port)
    # 必须放在带 .yaml 后缀的文件里: hysteria(viper) 靠扩展名判断配置类型,
    # 用 mktemp 生成的裸名会报 Unsupported Config Type
    tmp_dir=$(mktemp -d /tmp/hy2-validate.XXXXXX) || return 1
    tmp_conf=$tmp_dir/config.yaml
    log_file=$tmp_dir/output.log
    sed -e "s/^listen: :[0-9]*$/listen: :$trial_port/" "$conf_file" >"$tmp_conf"

    "$bin_file" server -c "$tmp_conf" >"$log_file" 2>&1 &
    pid=$!
    for i in 1 2 3 4 5 6; do
        sleep 0.5
        kill -0 "$pid" 2>/dev/null || break
        grep -qi 'server up and running' "$log_file" && break
    done
    if kill -0 "$pid" 2>/dev/null; then
        alive=1
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    else
        wait "$pid" 2>/dev/null
        rc=$?
    fi

    if grep -qi 'server up and running' "$log_file"; then
        rm -rf "$tmp_dir"
        return 0
    fi
    if [[ $alive == 1 && $rc == 0 ]] && ! grep -qi 'FATAL' "$log_file"; then
        rm -rf "$tmp_dir"
        return 0
    fi

    echo -e "${red}----- hysteria 自检输出 -----${none}" >&2
    tail -n 30 "$log_file" >&2
    echo -e "${red}----------------------------${none}" >&2
    rm -rf "$tmp_dir"
    return 1
}

# ---------------------------------------------------------------------------
# 客户端链接
# ---------------------------------------------------------------------------
build_link() {
    local host=$public_ip authority query name
    if [[ $host == *:* ]]; then
        authority="[$host]:$port"
    else
        authority="$host:$port"
    fi

    # 客户端对 query 只做 percent-decode, 所以一律用 quote(不能用 quote_plus, 空格会变 '+')
    query="sni=$(urlencode "$sni")&insecure=1"
    if [[ -n $obfs_password ]]; then
        query+="&obfs=salamander&obfs-password=$(urlencode "$obfs_password")"
    fi
    if [[ -n $pin_sha256 ]]; then
        query+="&pinSHA256=$(urlencode "$pin_sha256")"
    fi

    name=$(urlencode "${node_name:-HY2-$host}")
    echo "hysteria2://$(urlencode "$password")@$authority/?$query#$name"
}

# ---------------------------------------------------------------------------
# 系统层面收尾: 防火墙 / BBR / systemd
# ---------------------------------------------------------------------------
open_firewall() {
    local opened=0 policy
    if type -P ufw >/dev/null && ufw status 2>/dev/null | grep -qi 'Status: active'; then
        if ufw allow "$port"/udp >/dev/null 2>&1; then
            msg ok "ufw 已放行 udp/$port"
            opened=1
        fi
    fi
    if [[ $opened == 0 ]] && type -P firewall-cmd >/dev/null && firewall-cmd --state >/dev/null 2>&1; then
        if firewall-cmd --permanent --add-port="$port"/udp >/dev/null 2>&1 && firewall-cmd --reload >/dev/null 2>&1; then
            msg ok "firewalld 已放行 udp/$port"
            opened=1
        fi
    fi
    if [[ $opened == 0 ]] && type -P iptables >/dev/null; then
        policy=$(iptables -S INPUT 2>/dev/null | awk '$1 == "-P" { print $3; exit }')
        if [[ $policy == DROP || $policy == REJECT ]]; then
            if ! iptables -C INPUT -p udp --dport "$port" -j ACCEPT 2>/dev/null; then
                if iptables -I INPUT 1 -p udp --dport "$port" -j ACCEPT 2>/dev/null; then
                    warn "已插入 iptables 规则放行 udp/$port, 但 iptables 规则不会自动持久化, 重启后请检查(建议装 ufw/firewalld 或写 iptables-save)"
                    opened=1
                fi
            else
                opened=1
            fi
        fi
    fi
    if [[ $opened == 0 ]]; then
        msg "未检测到需要放行的本机防火墙(可能本来就放行)"
    fi
    warn "如云厂商有安全组/网络 ACL, 仍需在控制台放行 ${green}UDP $port${none} —— 只放行 TCP 是 Hysteria2 最常见的「日志正常却连不上」原因"
}

enable_bbr() {
    local cur
    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ $cur == bbr ]]; then
        msg ok "BBR 已启用"
        return 0
    fi
    msg "开启 BBR"
    modprobe tcp_bbr >/dev/null 2>&1
    cat >"$bbr_conf" <<'EOF'
# 由 install-hysteria2.sh 写入
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null 2>&1 || sysctl -p "$bbr_conf" >/dev/null 2>&1
    cur=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [[ $cur == bbr ]]; then
        msg ok "BBR 已启用(已写入 $bbr_conf, 重启后仍生效)"
    else
        warn "BBR 未能启用(内核可能不支持), 不影响 Hysteria2 使用"
    fi
}

install_service() {
    local unit
    unit="# 由 install-hysteria2.sh 生成
[Unit]
Description=Hysteria2 Proxy Server
Documentation=https://v2.hysteria.network/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$bin_file server -c $conf_file
WorkingDirectory=$HY2_HOME
Restart=always
RestartSec=3
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=yes
ProtectSystem=full
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
ProtectKernelTunables=yes
ProtectControlGroups=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
ReadWritePaths=$HY2_HOME

[Install]
WantedBy=multi-user.target
"
    printf '%s' "$unit" >"$service_file" || err "无法写入 $service_file"
    chmod 644 "$service_file"
    systemctl daemon-reload || err "systemctl daemon-reload 失败"
    systemctl enable "$service_name" >/dev/null 2>&1
    systemctl restart "$service_name" || {
        journalctl -u "$service_name" -n 30 --no-pager 2>/dev/null
        err "hysteria2 启动失败, 见上方日志"
    }

    # 起来之后确认服务在跑、UDP 端口真的在监听(和 install-reality.sh 一样做一次落地校验)
    local i
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if systemctl is-active --quiet "$service_name" && udp_port_in_use "$port"; then
            msg ok "服务已启动并监听 udp/$port"
            return 0
        fi
        sleep 1
    done
    if systemctl is-active --quiet "$service_name"; then
        warn "服务在运行, 但没检测到 udp/$port 监听(可能是 ss/netstat 缺失, 或日志里另有报错)"
        journalctl -u "$service_name" -n 20 --no-pager 2>/dev/null
        return 0
    fi
    journalctl -u "$service_name" -n 40 --no-pager 2>/dev/null
    err "hysteria2 未能在 10 秒内稳定运行, 请检查上方日志"
}

# ---------------------------------------------------------------------------
# 管理命令 hy2 (自包含, 不依赖本脚本在线)
# ---------------------------------------------------------------------------
hy2_template() {
    cat <<'HY2EOF'
#!/bin/bash
# Hysteria2 管理命令 —— 由 install-hysteria2.sh 生成
HY2_HOME="@HY2_HOME@"
SERVICE="@SERVICE@"
BIN="$HY2_HOME/hysteria"
CONF="$HY2_HOME/config.yaml"
META="$HY2_HOME/node.conf"
INFO="$HY2_HOME/info.txt"
REPO="@REPO@"
ASSET="@ASSET@"
VERSION="@VERSION@"
MIRRORS=("" "https://ghfast.top/" "https://gh-proxy.com/" "https://ghproxy.net/")

green='\e[92m'; red='\e[31m'; yellow='\e[33m'; none='\e[0m'
die() { echo -e "${red}$*${none}" >&2; exit 1; }
ok() { echo -e "${green}$*${none}"; }
warn() { echo -e "${yellow}$*${none}"; }

[[ $EUID == 0 ]] || die "请用 root 运行: sudo hy2 $*"

meta_get() {
    [[ -f $META ]] || return 0
    awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$META"
}

meta_set() {
    local k=$1 v=$2 tmp
    tmp=$(mktemp "$HY2_HOME/.node.conf.XXXXXX") || return 1
    [[ -f $META ]] && awk -F= -v k="$k" '$1 != k' "$META" >"$tmp"
    printf '%s=%s\n' "$k" "$v" >>"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$META"
}

udp_port_in_use() {
    local p=$1
    if type -P ss >/dev/null; then
        ss -lun 2>/dev/null | grep -qE "[:.]$p[[:space:]]"
    elif type -P netstat >/dev/null; then
        netstat -lun 2>/dev/null | grep -qE "[:.]$p[[:space:]]"
    else
        grep -qiE ":$p[[:space:]]" /proc/net/udp /proc/net/udp6 2>/dev/null
    fi
}

sha256_file() {
    if type -P sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'
    elif type -P shasum >/dev/null; then shasum -a 256 "$1" | awk '{print $1}'
    elif type -P openssl >/dev/null; then openssl dgst -sha256 "$1" | awk '{print $NF}'
    fi
}

# 小文件下载 -> stdout(没有 curl 就退回 wget)
get_url() {
    if type -P curl >/dev/null; then
        curl -fsSL --connect-timeout 15 "$1"
    else
        wget --no-check-certificate -q -T 20 -t 2 -O - "$1"
    fi
}

# 大文件下载 -> 文件
dl() {
    if type -P curl >/dev/null; then
        curl -fL --connect-timeout 15 --retry 2 -o "$2" "$1"
    else
        wget --no-check-certificate -T 20 -t 2 -O "$2" "$1"
    fi
}

show_info() {
    [[ -f $INFO ]] || die "找不到 $INFO, 请重新运行安装脚本"
    cat "$INFO"
}

case ${1:-help} in
start) systemctl start "$SERVICE" && ok "已启动" ;;
stop) systemctl stop "$SERVICE" && ok "已停止" ;;
restart) systemctl restart "$SERVICE" && ok "已重启" ;;
status)
    systemctl status "$SERVICE" --no-pager -l
    ;;
info) show_info ;;
link) [[ -f $HY2_HOME/client-link.txt ]] && cat "$HY2_HOME/client-link.txt" || show_info ;;
qr)
    command -v qrencode >/dev/null || die "未安装 qrencode, 先执行: apt-get install -y qrencode (或 yum install -y qrencode)"
    qrencode -t ANSIUTF8 -m 2 "$(cat "$HY2_HOME/client-link.txt")"
    ;;
log)
    shift
    journalctl -u "$SERVICE" -n "${1:-80}" --no-pager
    ;;
config)
    if [[ ${2:-} == edit ]]; then
        ${EDITOR:-vi} "$CONF"
        systemctl restart "$SERVICE" && ok "已重启以应用配置"
    else
        cat "$CONF"
    fi
    ;;
test)
    # 在随机空闲 UDP 端口上试启动, 不打扰正在跑的正式服务。
    # 配置文件必须带 .yaml 后缀(hysteria 用 viper, 靠扩展名判断类型)
    port=$(awk '/^listen:/ { gsub(/.*:/, ""); print; exit }' "$CONF")
    tmp_port=$(awk -v seed="$RANDOM" 'BEGIN { srand(seed); print 20000 + int(rand() * 40000) }')
    tmpd=$(mktemp -d /tmp/hy2-test.XXXXXX) || die "创建临时目录失败"
    tmp="$tmpd/config.yaml"
    log="$tmpd/output.log"
    sed -e "s/^listen: :[0-9]*\$/listen: :$tmp_port/" "$CONF" >"$tmp"
    "$BIN" server -c "$tmp" >"$log" 2>&1 &
    pid=$!
    for i in 1 2 3 4 5 6; do
        sleep 0.5
        kill -0 "$pid" 2>/dev/null || break
        grep -qi 'server up and running' "$log" && break
    done
    if kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        rm -rf "$tmpd"
        ok "配置自检通过 (listen :$port)"
        exit 0
    fi
    wait "$pid" 2>/dev/null
    if grep -qi 'server up and running' "$log"; then
        rm -rf "$tmpd"
        ok "配置自检通过 (listen :$port)"
        exit 0
    fi
    echo "----- hysteria 输出 -----"
    tail -n 30 "$log"
    rm -rf "$tmpd"
    die "配置自检失败"
    ;;
update)
    shift
    command -v curl >/dev/null || command -v wget >/dev/null || die "需要 curl 或 wget"
    target=${1:-latest}
    if [[ $target == latest ]]; then
        target=$(get_url "https://api.github.com/repos/$REPO/releases/latest" 2>/dev/null \
            | grep -o '"tag_name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -n1 \
            | sed -e 's/.*"tag_name"[[:space:]]*:[[:space:]]*"//' -e 's/"$//')
        [[ $target ]] || die "无法获取最新版本号, 请显式指定: hy2 update app/v2.13.0"
    fi
    echo "目标版本: $target"
    url="https://github.com/$REPO/releases/download/$target/$ASSET"
    hashes="https://github.com/$REPO/releases/download/$target/hashes.txt"
    expected=$(get_url "$hashes" 2>/dev/null | awk -v want="$ASSET" '
        { h = $1; sub(/^\*/, "", h); n = $NF; sub(/^.*\//, "", n);
          if (n == want && length(h) == 64 && h ~ /^[0-9a-fA-F]+$/) { print tolower(h); exit } }')
    [[ $expected ]] || warn "未取得 hashes.txt, 跳过 SHA256 校验"
    part="$HY2_HOME/.hysteria.update"
    for prefix in "${MIRRORS[@]}"; do
        rm -f "$part"
        echo "下载: ${prefix}${url}"
        if dl "${prefix}${url}" "$part"; then
            break
        fi
        rm -f "$part"
    done
    [[ -s $part ]] || die "下载失败"
    if [[ $expected ]]; then
        actual=$(sha256_file "$part")
        [[ $actual == "$expected" ]] || { rm -f "$part"; die "SHA256 不匹配: 期望 $expected 实际 $actual"; }
        ok "SHA256 校验通过"
    fi
    chmod 755 "$part"
    # 原子替换 + 重启; 先停服务避免 Text file busy
    systemctl stop "$SERVICE" 2>/dev/null
    mv -f "$part" "$BIN" || die "替换二进制失败"
    meta_set VERSION "$target"
    sed -i -e "s/^版本     : .*/版本     : $target/" "$INFO" 2>/dev/null
    systemctl start "$SERVICE"
    sleep 1
    if systemctl is-active --quiet "$SERVICE"; then
        ok "已更新到 $target 并重启"
    else
        journalctl -u "$SERVICE" -n 30 --no-pager
        die "新版本启动失败, 可用安装脚本回滚: bash install-hysteria2.sh --version <旧tag> --force"
    fi
    ;;
regen)
    if [[ -f $HY2_HOME/install.sh ]]; then
        exec bash "$HY2_HOME/install.sh" --regen
    fi
    die "找不到 $HY2_HOME/install.sh, 请重新运行安装脚本并加 --regen"
    ;;
uninstall)
    read -r -p "确认卸载 Hysteria2 及其配置? [y/N] " a
    [[ $a == y || $a == Y ]] || exit 0
    systemctl stop "$SERVICE" 2>/dev/null
    systemctl disable "$SERVICE" 2>/dev/null
    rm -f "/etc/systemd/system/$SERVICE.service"
    systemctl daemon-reload 2>/dev/null
    rm -rf "$HY2_HOME"
    rm -f "/usr/local/bin/hy2"
    ok "已卸载 (服务/配置/管理命令已清理)"
    warn "防火墙放行规则与 /etc/sysctl.d/99-hysteria2-bbr.conf 未自动回收, 如需清理请手动处理"
    ;;
help | -h | --help | *)
    cat <<'USAGE'
hy2 —— Hysteria2 管理命令

  hy2 start|stop|restart|status   服务控制
  hy2 info                        节点信息(链接/密码/SNI/端口)
  hy2 link                        只输出 hysteria2:// 链接
  hy2 qr                          输出二维码(需 qrencode)
  hy2 log [行数]                  查看服务日志
  hy2 config [edit]               查看/编辑配置(edit 后自动重启)
  hy2 test                        校验当前配置能否被 hysteria 接受
  hy2 update [tag]                更新二进制(latest 或指定 tag), 保留配置
  hy2 regen                       重新生成密码与证书(旧链接失效)
  hy2 uninstall                   卸载
USAGE
    ;;
esac
HY2EOF
}

install_manage_command() {
    local tpl
    tpl=$(hy2_template)
    tpl=${tpl//@HY2_HOME@/$HY2_HOME}
    tpl=${tpl//@SERVICE@/$service_name}
    tpl=${tpl//@REPO@/$hy2_repo}
    tpl=${tpl//@ASSET@/$hy_asset}
    tpl=${tpl//@VERSION@/$hy2_version}
    printf '%s\n' "$tpl" >"$cmd_file" || err "无法写入 $cmd_file"
    chmod 755 "$cmd_file"

    # 把安装脚本自身留一份, 供 hy2 regen 复用(管道执行时 $0 不是普通文件, 跳过)
    if [[ -f $0 ]] && [[ -r $0 ]]; then
        cp -f "$0" "$HY2_HOME/install.sh" 2>/dev/null && chmod 644 "$HY2_HOME/install.sh"
    fi
}

# ---------------------------------------------------------------------------
# 汇总输出
# ---------------------------------------------------------------------------
write_info() {
    local nl=$'\n' text
    text="Hysteria2 节点信息${nl}"
    text+="生成时间 : $(date '+%Y-%m-%d %H:%M:%S')${nl}"
    text+="版本     : $hy2_version${nl}"
    text+="服务器   : $public_ip:$port${nl}"
    text+="协议     : hysteria2 (QUIC/UDP)${nl}"
    text+="SNI      : $sni${nl}"
    text+="认证密码 : $password${nl}"
    if [[ -n $obfs_password ]]; then
        text+="混淆     : salamander / $obfs_password${nl}"
    fi
    [[ -n $pin_sha256 ]] && text+="pinSHA256: $pin_sha256${nl}"
    text+="配置     : $conf_file${nl}"
    text+="服务     : systemctl status $service_name   管理: hy2 help${nl}${nl}"
    text+="客户端链接(v2rayN / NekoBox / sing-box / Shadowrocket):${nl}${nl}"
    text+="$link${nl}"
    printf '%s\n' "$text" >"$info_file"
    printf '%s\n' "$link" >"$link_file"
    chmod 600 "$info_file" "$link_file"
}

print_summary() {
    echo
    echo -e "${cyan}==============================================================================${none}"
    echo -e "${green} Hysteria2 部署完成${none}  (UDP 单协议, 无 TCP 回退)"
    echo -e "${cyan}==============================================================================${none}"
    echo -e " 服务器   : ${magenta}$public_ip:$port${none}"
    echo -e " 端口     : ${magenta}udp/$port${none}"
    echo -e " SNI      : ${magenta}$sni${none}"
    echo -e " 密码     : ${magenta}$password${none}"
    [[ -n $obfs_password ]] && echo -e " 混淆     : ${magenta}salamander${none} / ${magenta}$obfs_password${none}"
    [[ -n $pin_sha256 ]] && echo -e " pinSHA256: ${gray}$pin_sha256${none}"
    echo -e " 配置文件 : $conf_file"
    echo -e " 管理命令 : ${green}hy2 {start|stop|restart|status|info|link|qr|log|config|test|update|regen|uninstall}${none}"
    echo
    echo -e "${green} 把下面这条链接导入 v2rayN / NekoBox / sing-box / Shadowrocket:${none}"
    echo
    echo -e "${magenta}$link${none}"
    echo
    if type -P qrencode >/dev/null; then
        qrencode -t ANSIUTF8 -m 2 "$link" 2>/dev/null || true
        echo
    else
        echo -e "${gray} (装上 qrencode 后可用 ${none}${green}hy2 qr${none}${gray} 直接出二维码)${none}"
        echo
    fi
    echo -e "${yellow} 连不上但服务器日志一切正常? 99% 是 UDP 没放行:${none}"
    echo -e "   - 云厂商安全组 / 网络 ACL 要放行 ${green}UDP $port${none}(很多人只放行了 TCP)"
    echo -e "   - 本机防火墙: ${green}hy2 status${none} 之外再看 ${green}ufw status${none} / ${green}firewall-cmd --list-all${none}"
    echo -e "   - 不要在客户端填 TCP/443 之类的假设, Hysteria2 只有 UDP"
    echo -e "${cyan}==============================================================================${none}"
    echo
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
    check_env

    # 重装/升级时沿用已有节点信息, 只让显式参数覆盖。
    # --regen 只重置密码与证书, 端口/SNI/混淆开关照样沿用, 否则"换个密码"会把端口也改回去。
    if [[ -f $meta_file ]]; then
        [[ $port_set == 0 && -n $(meta_get PORT) ]] && port=$(meta_get PORT)
        [[ $sni_set == 0 && -n $(meta_get SNI) ]] && sni=$(meta_get SNI)
        [[ $name_set == 0 && -n $(meta_get NODE_NAME) ]] && node_name=$(meta_get NODE_NAME)
        [[ -n $(meta_get MASQUERADE) && $masquerade == https://www.bing.com ]] && masquerade=$(meta_get MASQUERADE)
        if [[ $regen == 0 ]]; then
            [[ -n $password ]] || password=$(meta_get PASSWORD)
            [[ -n $obfs_password ]] || obfs_password=$(meta_get OBFS_PASSWORD)
        elif [[ -z $obfs_password && -n $(meta_get OBFS_PASSWORD) ]]; then
            obfs=1 # 原来开了混淆, 保持开启, 密码随后重新生成
        fi
        msg "检测到已有节点配置, 沿用现有端口/SNI$( [[ $regen == 0 ]] && echo '/密码/证书' || echo '(密码与证书将重新生成)')"
    fi

    # 校验参数
    if [[ ! $port =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
        err "端口不合法: $port"
    fi
    if [[ -z $sni ]] || [[ $sni == *" "* ]]; then
        err "SNI 不合法: '$sni'"
    fi
    if [[ -n $password ]]; then
        [[ $password == *$'\n'* ]] && err "密码里不能有换行"
        [[ $password == *" "* ]] && err "密码里不能有空格(客户端 URI 会解析失败)"
    fi
    if [[ -n $obfs_password && $obfs_password == *" "* ]]; then
        err "混淆密码里不能有空格"
    fi

    # --version latest
    if [[ $hy2_version == latest ]]; then
        local resolved
        resolved=$(resolve_latest_version) || err "无法获取最新版本号(网络受限?), 请显式指定: --version app/v2.13.0"
        hy2_version=$resolved
        msg "最新版本: $hy2_version"
    fi

    [[ $dry_run == 0 ]] || warn "dry-run 模式: 只生成文件并自检, 不安装服务/不改防火墙/不开 BBR"

    mkdir -p "$HY2_HOME" || err "无法创建 $HY2_HOME"
    [[ $EUID == 0 ]] && chmod 700 "$HY2_HOME"

    install_binary

    password=${password:-$(rand_password)}
    [[ -n $password ]] || err "生成密码失败"
    if [[ $obfs == 1 && -z $obfs_password ]]; then
        obfs_password=$(rand_password)
    fi

    ensure_cert
    render_config

    msg "校验生成的配置"
    validate_config || err "生成的配置没有通过 hysteria 自检, 见上方输出"
    msg ok "配置自检通过"

    public_ip=$(get_ip)
    [[ -n $public_ip ]] || {
        warn "获取公网 IP 失败, 客户端链接里用占位符, 请手动替换"
        public_ip="YOUR_SERVER_IP"
    }
    link=$(build_link)

    if [[ $dry_run == 1 ]]; then
        mkdir -p "$HY2_HOME"
        printf '%s\n' "$link" >"$HY2_HOME/client-link.txt.dry"
        echo
        _green "===== dry-run 结果 ====="
        echo "配置文件: $conf_file"
        cat "$conf_file"
        echo
        echo "客户端链接:"
        echo "$link"
        echo
        _yellow "未安装 systemd 服务 / 未改防火墙 / 未开 BBR。"
        exit 0
    fi

    [[ $fw == 1 ]] && open_firewall
    [[ $bbr == 1 ]] && enable_bbr
    install_service
    install_manage_command

    meta_set VERSION "$hy2_version"
    meta_set PORT "$port"
    meta_set SNI "$sni"
    meta_set PASSWORD "$password"
    meta_set OBFS_PASSWORD "$obfs_password"
    meta_set PIN_SHA256 "$pin_sha256"
    meta_set NODE_NAME "${node_name:-HY2-$public_ip}"
    meta_set MASQUERADE "$masquerade"
    meta_set LINK "$link"
    meta_set UPDATED "$(date '+%Y-%m-%d %H:%M:%S')"

    write_info
    print_summary
}

main
