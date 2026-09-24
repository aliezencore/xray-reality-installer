#!/bin/bash
#
# Xray + VLESS+REALITY 一键安装脚本
# 基于 233boy/v2ray install.sh 框架改造:
#   - 核心: v2ray -> Xray (REALITY 仅 Xray 支持)
#   - 不再依赖远程下载的 code.zip 管理脚本(供应链风险 + 版本漂移), 管理命令内置
#   - systemd 服务带 Restart 策略 / 文件描述符上限 / 基础沙箱加固
#   - 默认开启 BBR (sysctl.d 持久化)
#   - 下载校验 SHA256(.dgst), 兼容多种格式, 解析失败显式警告而非静默跳过
#   - 多源获取公网 IP (不走下载代理, 避免拿到代理出口 IP)
#   - 三级端口占用检测 (ss / netstat / /proc) + 配置生成后 xray -test 自检
#   - 自动放行防火墙 (firewalld / ufw)
#   - 可选附加: HTTPS 正向代理 (https://user:pass@ip:port, 自签证书 + 随机账号密码)
#
# 用法:
#   bash install-reality.sh [--port 443] [--sni www.microsoft.com] [--name 节点名]
#        [--https-proxy] [--https-proxy-port 3128]
#        [--proxy http://127.0.0.1:2333] [--version v25.x.x]
#
# 端口:
#   很多 VPS 商家只在安全组里放行了少数端口, 所以交互终端下运行且未给 --port 时,
#   脚本会提示输入端口(填你已放行的那个), 端口被占用也会重新询问而不是直接退出;
#   管道/CI 等非交互环境不提示, 直接用 --port 或默认 443。
#
# 装完后管理命令: xray {start|stop|restart|status|info|log|loglevel|conn|config|test|bbr|update|uninstall}

# ---------------------------------------------------------------------------
# 颜色与输出 (沿用原脚本风格)
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

msg() {
    case $1 in
    warn) local color=$yellow ;;
    err) local color=$red ;;
    ok) local color=$green ;;
    esac
    echo -e "${color}$(date +'%T')${none}) ${2}"
}

# ---------------------------------------------------------------------------
# 环境检查
# ---------------------------------------------------------------------------
[[ $EUID != 0 ]] && err "当前非 ${yellow}ROOT用户.${none}"

# 防 Windows 换行符: 脚本被 CRLF 污染时, 所有 heredoc 都会写坏(如 systemd unit 导致 203/EXEC)
if grep -q $'\r' "$0" 2>/dev/null; then
    err "脚本包含 Windows 换行符(CRLF), 先执行: ${green}sed -i 's/\r\$//' $0${none} 再重新运行"
fi

cmd=$(type -P apt-get || type -P yum)
[[ ! $cmd ]] && err "此脚本仅支持 ${yellow}(Ubuntu or Debian or CentOS)${none}."

[[ ! $(type -P systemctl) ]] && {
    err "此系统缺少 ${yellow}(systemctl)${none}, 请尝试执行:${yellow} ${cmd} update -y;${cmd} install systemd -y ${none}来修复此错误."
}

case $(uname -m) in
amd64 | x86_64)
    core_arch="64"
    jq_arch="amd64"
    ;;
*aarch64* | *armv8*)
    core_arch="arm64-v8a"
    jq_arch="arm64"
    ;;
*)
    err "此脚本仅支持 64 位系统..."
    ;;
esac

# ---------------------------------------------------------------------------
# 安装路径
# ---------------------------------------------------------------------------
bin_dir=/etc/xray/bin
conf_file=/etc/xray/config.json
info_file=/etc/xray/info.txt
is_core_bin=$bin_dir/xray
hp_cert=/etc/xray/hp-cert.pem
hp_key=/etc/xray/hp-key.pem

# 可选项状态
hp_enabled=""
hp_port=""
hp_user=""
hp_pass=""

# 交互式端口输入的返回值 (见 ask_port_value)
_picked=""

# ---------------------------------------------------------------------------
# 小工具
# ---------------------------------------------------------------------------
# wget add --no-check-certificate, 支持 --proxy
# 注意: 代理仅对单次调用生效(命令前缀赋值), 不污染脚本环境,
#       否则 get_ip 会拿到代理出口 IP 而非本机 IP
_wget() {
    if [[ $proxy ]]; then
        https_proxy=$proxy wget --no-check-certificate "$@"
    else
        wget --no-check-certificate "$@"
    fi
}

# 多源获取公网 IPv4 (直连, 刻意不走 --proxy; -t 1 避免默认 20 次重试拖慢)
get_ip() {
    ip=$(wget -4 -t 1 -T 5 -qO- --no-check-certificate https://one.one.one.one/cdn-cgi/trace 2>/dev/null | awk -F= '/^ip=/{print $2}')
    [[ -z $ip ]] && ip=$(wget -4 -t 1 -T 5 -qO- --no-check-certificate https://api.ipify.org 2>/dev/null)
    [[ -z $ip ]] && ip=$(wget -4 -t 1 -T 5 -qO- --no-check-certificate https://ipinfo.io/ip 2>/dev/null)
    ip=$(echo "$ip" | tr -d ' \t\r\n')
}

# 随机 hex, $1 为字节数 (shortId 用 4 字节 => 8 个 hex)
rand_hex() {
    if type -P openssl >/dev/null; then
        openssl rand -hex "$1"
    else
        head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'
    fi
}

# 域名格式校验 (用于 --sni, 防止 shell 元字符进入 /dev/tcp 拼接)
valid_domain() {
    [[ $1 =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)+$ ]]
}

# URL 编码(有 python3 时), 否则手工转义常见危险字符
urlencode() {
    if type -P python3 >/dev/null; then
        python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=''))" "$1" 2>/dev/null
    else
        echo "$1" | sed -e 's/%/%25/g' -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g' -e 's/&/%26/g' -e 's/=/%3D/g' -e 's/@/%40/g' -e 's/:/%3A/g'
    fi
}

# ---------------------------------------------------------------------------
# 安装依赖: wget unzip openssl; jq 缺失则下载安装
# ---------------------------------------------------------------------------
install_pkg() {
    local not_found=""
    for i in "$@"; do
        [[ ! $(type -P $i) ]] && not_found="$not_found $i"
    done
    if [[ $not_found ]]; then
        msg warn "安装依赖包 >${not_found}"
        $cmd install -y $not_found &>/dev/null || {
            [[ $cmd =~ yum ]] && yum install epel-release -y &>/dev/null
            $cmd update -y &>/dev/null
            $cmd install -y $not_found &>/dev/null
        }
    fi
    for i in "$@"; do
        [[ ! $(type -P $i) ]] && err "依赖安装失败: $i, 请手动执行: $cmd install -y $i"
    done
}

install_jq() {
    type -P jq >/dev/null && return
    msg warn "下载 jq ..."
    # 先下载到临时目录并验证可执行, 再落位, 避免中断留下半截 /usr/bin/jq
    local tmp
    tmp=$(mktemp -d) || err "创建临时目录失败"
    _wget -t 3 -q "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-$jq_arch" -O $tmp/jq \
        || {
        rm -rf $tmp
        err "下载 jq 失败"
    }
    chmod +x $tmp/jq
    $tmp/jq --version >/dev/null 2>&1 || {
        rm -rf $tmp
        err "下载的 jq 无法执行"
    }
    mv -f $tmp/jq /usr/bin/jq
    rm -rf $tmp
}

# ---------------------------------------------------------------------------
# 下载 Xray core (带 sha256 校验, 格式兼容 SHA2-256= / SHA256= 等写法)
# ---------------------------------------------------------------------------
download_core() {
    mkdir -p $bin_dir
    local ver_path="latest/download"
    [[ $core_ver ]] && ver_path="download/$core_ver"
    local url="https://github.com/XTLS/Xray-core/releases/$ver_path/Xray-linux-$core_arch.zip"
    local tmp
    tmp=$(mktemp -d) || err "创建临时目录失败"
    trap 'rm -rf "$tmp"' EXIT

    msg warn "下载 Xray ${core_ver:-latest} > $url"
    _wget -t 3 -q -c "$url" -O $tmp/xray.zip || {
        trap - EXIT
        rm -rf $tmp
        err "下载 Xray 失败"
    }

    # 校验 SHA256: .dgst 行内含 64 位 hex, 宽容匹配多种写法
    if _wget -t 2 -q -O $tmp/xray.zip.dgst "$url.dgst" 2>/dev/null; then
        local expect
        expect=$(grep -iE 'sha2?-?256' $tmp/xray.zip.dgst | grep -oE '\b[a-fA-F0-9]{64}\b' | head -1 | tr 'A-Z' 'a-z')
        if [[ -n $expect ]]; then
            local actual
            actual=$(sha256sum $tmp/xray.zip | awk '{print $1}')
            [[ $actual == "$expect" ]] || {
                trap - EXIT
                rm -rf $tmp
                err "Xray 下载校验失败 (sha256 不匹配), 请重试"
            }
            msg ok "sha256 校验通过"
        else
            msg warn "未能从 .dgst 解析出 SHA256, 跳过校验"
        fi
    else
        msg warn "下载 .dgst 失败, 跳过校验"
    fi

    unzip -qo $tmp/xray.zip -d $tmp/x || {
        trap - EXIT
        rm -rf $tmp
        err "Xray 压缩包解压失败"
    }
    [[ -f $tmp/x/xray ]] || {
        trap - EXIT
        rm -rf $tmp
        err "Xray 压缩包中缺少 xray 二进制"
    }

    mv -f $tmp/x/xray $is_core_bin
    chmod +x $is_core_bin
    for f in geoip.dat geosite.dat; do
        [[ -f $tmp/x/$f ]] && mv -f $tmp/x/$f $bin_dir/$f
    done
    trap - EXIT
    rm -rf $tmp

    $is_core_bin version >/dev/null 2>&1 || err "Xray 无法执行, 请检查系统兼容性"
    msg ok "Xray $($is_core_bin version | head -1)"
}

# ---------------------------------------------------------------------------
# SNI 探测: TCP 443 可达 + TLS 1.3 支持 (REALITY 必需 TLS1.3)
# 候选原则: 大厂但低调的境外站优先, 降低被扫描工具盯防并举报商家的风险
# (参考 linux.do/t/topic/2854265: CF 站点及微软域名被点名, 商家会封机)
# 全部候选实测: TLS1.3 + h2 + 非 Cloudflare + 境外基础设施 (2026-09)
# ---------------------------------------------------------------------------
SNI_CANDIDATES=(
    www.samsung.com
    www.amd.com
    www.sony.com
    www.tesla.com
    www.intel.com
    addons.mozilla.org
    cici.com
    coze.com
    www.apple.com
    www.amazon.com
    www.ibm.com
    www.nvidia.com
    dl.google.com
    www.microsoft.com
)

# 检测域名是否套 Cloudflare (直连探测, 同 Xray 拨 dest 的路径)
is_cf() {
    wget -S --spider -q -T 8 -t 1 "https://$1" -O /dev/null 2>&1 | grep -qiE 'cf-ray|server: *cloudflare'
}

sni_ok() {
    local sni=$1
    getent ahostsv4 "$sni" >/dev/null 2>&1 || return 1
    timeout 3 bash -c "echo >/dev/tcp/$sni/443" 2>/dev/null || return 1
    # 仅当本地 openssl 支持 TLS1.3 时才校验 dest (CentOS 7 的 openssl 1.0.2 无 -tls1_3, 跳过则不阻塞)
    if type -P openssl >/dev/null && openssl s_client -help 2>&1 | grep -q -- '-tls1_3'; then
        echo | timeout 5 openssl s_client -connect "$sni:443" -servername "$sni" -tls1_3 2>/dev/null \
            | grep -q "TLSv1.3" || return 1
    fi
    return 0
}

select_sni() {
    [[ $sni_arg ]] && {
        sni_ok "$sni_arg" || err "指定 SNI ($sni_arg) 不可用(443 不通或不支持 TLS 1.3)"
        sni=$sni_arg
        if is_cf "$sni_arg"; then
            warn "指定 SNI ($sni_arg) 套了 Cloudflare, 有被扫描举报导致商家封机的风险, 强烈建议更换 (参考 linux.do/t/topic/2854265)"
        fi
        msg ok "使用指定 SNI: $sni"
        return
    }
    msg warn "探测 REALITY 伪装站点 (需要 443 可达且支持 TLS 1.3) ..."
    for candidate in "${SNI_CANDIDATES[@]}"; do
        msg warn "  测试 $candidate ..."
        if sni_ok "$candidate" && ! is_cf "$candidate"; then
            sni=$candidate
            msg ok "选定 SNI: $sni"
            return
        fi
    done
    err "没有找到可用的伪装站点, 请用 --sni 手动指定一个支持 TLS 1.3 的域名"
}

# ---------------------------------------------------------------------------
# 端口占用检测: ss / netstat / /proc 三级, $1 为端口
# 之前在无 ss/netstat 的机器上会假阴性(认为端口空闲), 现兜底解析 /proc
# ---------------------------------------------------------------------------
check_port() {
    local p=$1
    if type -P ss >/dev/null; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p$" && return 1
    elif type -P netstat >/dev/null; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$p$" && return 1
    elif [[ -r /proc/net/tcp || -r /proc/net/tcp6 ]]; then
        awk -v h=":$(printf '%04X' "$p")" '$4 == "0A" && index($2, h) > 0' \
            /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -q . && return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 防火墙放行 (firewalld / ufw), 参数为端口列表
# ---------------------------------------------------------------------------
open_firewall() {
    local p opened=""
    if type -P firewall-cmd >/dev/null && systemctl is-active -q firewalld 2>/dev/null; then
        for p in "$@"; do
            firewall-cmd --permanent --add-port=$p/tcp &>/dev/null && opened="$opened $p"
        done
        firewall-cmd --reload &>/dev/null
        [[ $opened ]] && msg ok "防火墙(firewalld)已放行 TCP 端口:$opened"
    elif type -P ufw >/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        for p in "$@"; do
            ufw allow $p/tcp &>/dev/null && opened="$opened $p"
        done
        [[ $opened ]] && msg ok "防火墙(ufw)已放行 TCP 端口:$opened"
    fi
    [[ $opened ]] || msg warn "未检测到运行中的防火墙(firewalld/ufw), 如客户端无法连接请自行放行 TCP 端口:$*"
}

# ---------------------------------------------------------------------------
# BBR 状态检测: 打印诊断信息, 返回 0 表示已启用
# 判据是内核当前实际生效的拥塞控制算法, 而不是"配置文件写了没有"
# ---------------------------------------------------------------------------
bbr_check() {
    local kver cc avail qdisc
    kver=$(uname -r)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    # 去掉可能的空白, 避免 sysctl 输出带杂质时把 == 比较搞失败
    cc=${cc//[[:space:]]/}
    qdisc=${qdisc//[[:space:]]/}

    echo -e "  内核版本 : ${green}${kver:-未知}${none}"
    echo -e "  当前算法 : ${green}${cc:-读取失败}${none}"
    echo -e "  可用算法 : ${gray}${avail:-读取失败}${none}"
    echo -e "  队列算法 : ${gray}${qdisc:-读取失败}${none}"

    [[ $cc == bbr ]] || return 1
    [[ $qdisc == fq || $qdisc == fq_codel ]] || \
        warn "队列算法是 ${qdisc:-空}, 建议设为 fq —— BBR 的配套队列, 不带 fq 效果会打折"
    return 0
}

# ---------------------------------------------------------------------------
# BBR 优化 (sysctl.d 持久化, 幂等)
# ---------------------------------------------------------------------------
enable_bbr() {
    msg warn "检查 BBR ..."
    if bbr_check; then
        msg ok "BBR 已开启"
        return
    fi

    cat >/etc/sysctl.d/99-xray-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl -p /etc/sysctl.d/99-xray-bbr.conf >/dev/null 2>&1

    if bbr_check; then
        msg ok "BBR 已开启 (配置已写入 /etc/sysctl.d/99-xray-bbr.conf, 重启后依然生效)"
        return
    fi

    # 未生效时区分两种原因, 而不是笼统地说"内核不支持"
    if [[ $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null) != *bbr* ]]; then
        warn "内核不支持 BBR(可用算法列表里没有 bbr), 不影响 REALITY 使用"
        warn "  需要内核 >= 4.9; 若为 OpenVZ/LXC 等共享宿主内核的容器, 宿主机不换内核就无法开启"
    else
        warn "内核支持 BBR 但设置未生效, 手动执行看具体报错(常见: 容器内 /proc/sys 只读):"
        echo -e "  ${green}sysctl -w net.ipv4.tcp_congestion_control=bbr${none}"
    fi
}

# ---------------------------------------------------------------------------
# 交互式端口输入 (结果写入全局 _picked)
#   $1 提示语  $2 默认值(为空表示必填)  $3 端口用途(报错文案)  $4 需排除的端口(可选)
# 注意: 提示与错误信息一律走 stderr, 避免污染调用方的输出
# ---------------------------------------------------------------------------
ask_port_value() {
    local tip=$1 def=$2 label=${3:-端口} exclude=${4:-} ans
    while :; do
        if [[ $def ]]; then
            read -r -p "$tip [默认 $def]: " ans || return 1
        else
            read -r -p "$tip (1-65535): " ans || return 1
        fi
        ans=${ans// /}
        # 去掉 CR/TAB: Windows 终端粘贴或 CRLF 环境可能带进来, 否则会被判成非法输入
        ans=${ans//$'\r'/}
        ans=${ans//$'\t'/}
        [[ -z $ans && $def ]] && ans=$def
        # 长度先卡一道, 防止超长数字在 10# 运算里溢出后"碰巧"落在合法区间
        if [[ ${#ans} -gt 5 || ! $ans =~ ^[0-9]+$ ]] || (( 10#$ans < 1 || 10#$ans > 65535 )); then
            echo -e "${yellow}$label 无效: ${ans:-空}, 请输入 1-65535 之间的数字${none}" >&2
            continue
        fi
        ans=$((10#$ans))
        if [[ -n $exclude && $ans == "$exclude" ]]; then
            echo -e "${yellow}$label 不能与 REALITY 监听端口相同 ($exclude)${none}" >&2
            continue
        fi
        if ! check_port "$ans"; then
            echo -e "${yellow}$label $ans 已被占用, 请换一个${none}" >&2
            continue
        fi
        _picked=$ans
        return 0
    done
}

# ---------------------------------------------------------------------------
# 主监听端口: --port 优先; 交互终端下提示输入; 非交互环境用默认 443
# 商家安全组只放行部分端口时, 必须让用户自己填, 不能替他随机挑
# ---------------------------------------------------------------------------
ask_port() {
    if [[ $port ]]; then
        if check_port "$port"; then
            msg ok "REALITY 监听端口: $port"
            return 0
        fi
        if [[ -t 0 ]]; then
            warn "端口 $port 已被占用, 请重新指定"
            port=""
        else
            err "端口 $port 已被占用, 请用 --port 指定其他端口"
        fi
    fi
    if [[ -t 0 ]]; then
        echo
        echo -e "${cyan}提示: 多数 VPS 商家只在安全组放行了少数端口, 请填写你已放行的端口${none}"
        ask_port_value "请输入 REALITY 监听端口" 443 "端口" || err "读取端口失败"
        port=$_picked
    else
        port=443
        msg warn "非交互环境且未指定 --port, 使用默认端口 443"
    fi
    msg ok "REALITY 监听端口: $port"
}

# ---------------------------------------------------------------------------
# 询问是否附加安装 HTTPS 正向代理 (https://user:pass@ip:port)
# 交互终端下询问; 非交互环境(自动化)用 --https-proxy / --https-proxy-port 启用
# ---------------------------------------------------------------------------
ask_https_proxy() {
    local ans
    if [[ $hp_enabled ]]; then
        :
    elif [[ -t 0 ]]; then
        echo
        read -r -p "是否附加安装一个 HTTPS 正向代理? (https://ip:port, 可供 curl/程序挂代理用, 账号密码随机) [y/N]: " ans
        ans=${ans// /}
        ans=${ans//$'\r'/}
        [[ $ans == y || $ans == Y || $ans == yes || $ans == YES ]] && hp_enabled=1
    else
        msg warn "非交互环境, 跳过 HTTPS 正向代理 (如需安装请加参数 --https-proxy)"
    fi
    if [[ $hp_enabled ]]; then
        if [[ ! $hp_port ]]; then
            # 先挑一个随机空闲端口(且不与主端口冲突)作为默认值
            local rand_port="" tries=0
            while (( tries < 50 )); do
                rand_port=$(( (RANDOM % 40000) + 20000 ))
                [[ $rand_port != "$port" ]] && check_port "$rand_port" && break
                rand_port=""
                (( tries++ ))
            done
            if [[ -t 0 ]]; then
                # 交互模式: 回车用随机端口, 也可填写商家已放行的端口
                ask_port_value "请输入 HTTPS 代理端口" "$rand_port" "HTTPS 代理端口" "$port" \
                    || err "读取 HTTPS 代理端口失败"
                hp_port=$_picked
            else
                [[ -z $rand_port ]] && err "找不到空闲的 HTTPS 代理端口, 请用 --https-proxy-port 指定"
                hp_port=$rand_port
            fi
        fi
        [[ $hp_port == "$port" ]] && err "HTTPS 代理端口与主端口相同: $port"
        check_port "$hp_port" || err "HTTPS 代理端口 $hp_port 已被占用, 请用 --https-proxy-port 指定其他端口"
        msg ok "HTTPS 正向代理: 端口 $hp_port (账号密码安装时随机生成)"
    fi
}

# ---------------------------------------------------------------------------
# 生成配置 + 节点信息 + 客户端链接
# ---------------------------------------------------------------------------
gen_config() {
    mkdir -p /etc/xray

    # 密钥对 (兼容三代输出: "Public key: x" / "PublicKey:x" / "Password (PublicKey): x")
    local key_out
    key_out=$($is_core_bin x25519)
    private_key=$(echo "$key_out" | sed -nE 's/^[[:space:]]*[Pp]rivate[ _]?[Kk]ey[^A-Za-z0-9]*([A-Za-z0-9_-]{30,}).*/\1/p' | head -1 | tr -d '\r')
    public_key=$(echo "$key_out" | sed -nE 's/.*[Pp]ublic[ _]?[Kk]ey[^A-Za-z0-9]*([A-Za-z0-9_-]{30,}).*/\1/p' | head -1 | tr -d '\r')
    [[ -z $private_key || -z $public_key ]] && {
        echo "$key_out" | head -5
        err "x25519 密钥生成/解析失败"
    }

    # UUID
    uuid=$($is_core_bin uuid)
    [[ -z $uuid ]] && uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null)
    [[ -z $uuid ]] && err "UUID 生成失败"

    # shortId: 8 个 hex 字符 (安全参数, 生成失败直接报错, 不用硬编码默认值)
    short_id=$(rand_hex 4)
    [[ ${#short_id} != 8 ]] && err "shortId 生成失败"

    # 附加 HTTPS 代理: 自签证书 (openssl 1.0.2 无 -addext, 降级重试) + 随机账号
    if [[ $hp_enabled ]]; then
        openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
            -keyout $hp_key -out $hp_cert -subj "/CN=$ip" \
            -addext "subjectAltName=IP:$ip" &>/dev/null \
            || openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
                -keyout $hp_key -out $hp_cert -subj "/CN=$ip" &>/dev/null \
            || err "HTTPS 代理自签证书生成失败"
        chmod 600 $hp_key
        hp_user="u$(rand_hex 3)"
        hp_pass=$(rand_hex 16)
    fi

    # 写入 config.json (jq 构造, 避免手写 JSON 出错)
    jq -n \
        --arg uuid "$uuid" \
        --arg flow "xtls-rprx-vision" \
        --arg listen "0.0.0.0" \
        --argjson port "$port" \
        --arg sni "$sni" \
        --arg dest "$sni:443" \
        --arg privateKey "$private_key" \
        --arg shortId "$short_id" \
        --argjson hpEnabled "$([[ $hp_enabled ]] && echo true || echo false)" \
        --argjson hpPort "${hp_port:-0}" \
        --arg hpUser "$hp_user" \
        --arg hpPass "$hp_pass" \
        --arg hpCert "$hp_cert" \
        --arg hpKey "$hp_key" \
        '{
            log: {loglevel: "warning"},
            inbounds: (
                [{
                    listen: $listen,
                    port: $port,
                    protocol: "vless",
                    settings: {
                        clients: [{id: $uuid, flow: $flow}],
                        decryption: "none"
                    },
                    streamSettings: {
                        network: "tcp",
                        security: "reality",
                        realitySettings: {
                            show: false,
                            dest: $dest,
                            xver: 0,
                            serverNames: [$sni],
                            privateKey: $privateKey,
                            shortIds: [$shortId]
                        }
                    },
                    sniffing: {enabled: true, destOverride: ["http", "tls"]}
                }]
                + (if $hpEnabled then [{
                        listen: "0.0.0.0",
                        port: $hpPort,
                        protocol: "http",
                        settings: {
                            accounts: [{user: $hpUser, pass: $hpPass}]
                        },
                        streamSettings: {
                            security: "tls",
                            tlsSettings: {
                                certificates: [{certificateFile: $hpCert, keyFile: $hpKey}]
                            }
                        }
                    }] else [] end)
            ),
            outbounds: [{protocol: "freedom", tag: "direct"}]
        }' >$conf_file || err "生成配置失败"
    chmod 600 $conf_file

    # xray 自检
    $is_core_bin run -test -config $conf_file >/dev/null 2>&1 \
        || err "配置自检未通过, 请检查: $is_core_bin run -test -config $conf_file"

    # 客户端链接
    local name_enc
    name_enc=$(urlencode "${node_name:-VPS-REALITY}")
    link="vless://$uuid@$ip:$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=chrome&pbk=$public_key&sid=$short_id&type=tcp&headerType=none#$name_enc"

    # 节点信息文件
    cat >$info_file <<EOF
========== Xray VLESS + REALITY 节点信息 ==========
地址 (Address)    : $ip
端口 (Port)       : $port
SNI               : $sni
UUID              : $uuid
Flow              : xtls-rprx-vision
PublicKey (pbk)   : $public_key
ShortId (sid)     : $short_id
指纹 (fp)         : chrome

客户端链接:
$link

说明: 伪装站点为 $sni:443, 非 REALITY 流量会自动透明回落至该站点。
管理命令: xray {start|stop|restart|status|info|log|loglevel|conn|config|test|bbr|update|uninstall}
====================================================
EOF
    if [[ $hp_enabled ]]; then
        cat >>$info_file <<EOF

---------- 附加: HTTPS 正向代理 ----------
代理地址: https://$hp_user:$hp_pass@$ip:$hp_port
curl 示例: curl -x https://$hp_user:$hp_pass@$ip:$hp_port --proxy-insecure https://www.google.com
说明: 证书为自签(CN/SAN 绑定 $ip), 客户端需忽略代理证书校验(curl 加 --proxy-insecure,
      Python requests 用 verify=False); 账号密码随机生成, 请勿泄露。
====================================================
EOF
    fi
    chmod 600 $info_file
}

# ---------------------------------------------------------------------------
# systemd 服务
# ---------------------------------------------------------------------------
install_service() {
    cat >/etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service (VLESS+REALITY)
After=network.target nss-lookup.target

[Service]
Type=simple
ExecStart=$is_core_bin run -config $conf_file
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
Environment=XRAY_LOCATION_ASSET=/etc/xray/bin
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true

[Install]
WantedBy=multi-user.target
EOF
    # 防 CRLF 污染单元文件(经 Windows 拷贝/编辑的场景)
    sed -i 's/\r$//' /etc/systemd/system/xray.service
    # SELinux 强制模式下给二进制打 bin_t 标签, 否则 systemd 无法执行, 服务 203/EXEC 崩溃循环
    if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce) == Enforcing ]]; then
        if command -v semanage >/dev/null 2>&1; then
            semanage fcontext -a -t bin_t "/etc/xray/bin(/.*)?" &>/dev/null
            restorecon -Rv /etc/xray/bin &>/dev/null
        elif command -v chcon >/dev/null 2>&1; then
            chcon -t bin_t $is_core_bin &>/dev/null \
                || warn "SELinux 标签设置失败, 若服务起不来请手动执行: chcon -t bin_t $is_core_bin"
        fi
    fi
    systemctl daemon-reload
    systemctl enable xray &>/dev/null
    systemctl start xray
    # 启动探测: 循环等待最多 5s, 避免机器慢导致误报失败
    local ok=0
    for i in {1..10}; do
        systemctl is-active -q xray && {
            ok=1
            break
        }
        sleep 0.5
    done
    [[ $ok == 1 ]] || {
        journalctl -u xray -n 20 --no-pager 2>/dev/null | tail -20
        err "Xray 启动失败(常见: SELinux 的 203/EXEC、端口被占), 按上方日志处理后: systemctl restart xray"
    }
    # active 不等于端口真的在监听, 再确认一次
    local listen_ok=0
    for i in {1..10}; do
        ss -ltn 2>/dev/null | grep -q ":$port " && {
            listen_ok=1
            break
        }
        sleep 0.5
    done
    [[ $listen_ok == 1 ]] || {
        journalctl -u xray -n 20 --no-pager 2>/dev/null | tail -20
        err "Xray 已 active 但端口 $port 未监听, 按上方日志排查"
    }
    msg ok "Xray 服务已启动, 端口 $port 监听中"
}

# ---------------------------------------------------------------------------
# 管理命令 (写入 /usr/local/bin/xray, 供日常使用)
# ---------------------------------------------------------------------------
install_cli() {
    cat >/usr/local/bin/xray <<'EOF'
#!/bin/bash
# Xray (VLESS+REALITY) 管理命令 — 由 install-reality.sh 生成
bin=/etc/xray/bin/xray
bindir=/etc/xray/bin
conf=/etc/xray/config.json
info=/etc/xray/info.txt

usage() {
    cat <<HELP
用法: xray <command>
  start      启动 Xray
  stop       停止 Xray
  restart    重启 Xray
  status     查看运行状态(服务/监听端口/在线连接/重启次数)
  info       查看节点信息和客户端链接
  log        跟踪查看日志 (journalctl)
  loglevel   查看或设置日志级别 (排障先设为 info)
  conn       列出当前已建立的连接
  config     查看当前配置
  test       校验配置
  bbr        查看 BBR 加速状态(拥塞控制/队列算法)
  update     更新 Xray 到最新版 (含 geo 数据)
  uninstall  卸载 Xray (停止服务并删除文件)
HELP
}

case $1 in
start | stop | restart)
    systemctl $1 xray
    ;;
status)
    systemctl status xray --no-pager -l 2>/dev/null | head -12
    echo
    if systemctl is-active -q xray 2>/dev/null; then
        echo "--- 运行详情 ---"
        echo "  启动时间 : $(systemctl show xray -p ActiveEnterTimestamp --value 2>/dev/null)"
        echo "  重启次数 : $(systemctl show xray -p NRestarts --value 2>/dev/null)"
        lv=$(command -v jq >/dev/null 2>&1 && jq -r '.log.loglevel // "warning"' $conf 2>/dev/null)
        echo "  日志级别 : ${lv:-未知}    (改级别: xray loglevel info)"
        port=$(command -v jq >/dev/null 2>&1 && jq -r '.inbounds[0].port // empty' $conf 2>/dev/null)
        if [[ $port ]] && command -v ss >/dev/null 2>&1; then
            # active 不代表端口真的在听, 所以单独确认一次
            if ss -ltn 2>/dev/null | grep -q ":$port "; then
                echo "  监听端口 : $port (监听中)"
            else
                echo "  监听端口 : $port (未监听! 执行 xray log 看日志)"
            fi
            echo "  在线连接 : $(ss -tn state established "sport = :$port" 2>/dev/null | grep -c ESTAB) 条"
        fi
    else
        echo "服务未运行: xray start 启动; 启动失败请看 xray log"
    fi
    ;;
info)
    [[ -f $info ]] && cat $info || echo "节点信息文件不存在: $info"
    ;;
log)
    lv=$(command -v jq >/dev/null 2>&1 && jq -r '.log.loglevel // "warning"' $conf 2>/dev/null)
    echo "当前日志级别: ${lv:-未知}"
    case $lv in
    none | error | warning)
        echo "提示: 该级别下正常运行几乎不产生日志 —— 看不到内容不代表没连上。"
        echo "      排障请先执行: xray loglevel info"
        ;;
    esac
    echo "--- journalctl -u xray -n 80 -f (Ctrl-C 退出) ---"
    journalctl -u xray -n 80 -f
    ;;
loglevel)
    cur=$(command -v jq >/dev/null 2>&1 && jq -r '.log.loglevel // "warning"' $conf 2>/dev/null)
    if [[ -z $2 ]]; then
        echo "当前日志级别: ${cur:-未知}"
        echo
        echo "用法: xray loglevel <级别>"
        echo "  none     完全静默"
        echo "  error    只记错误"
        echo "  warning  默认值, 正常运行几乎无输出"
        echo "  info     记录连接与出站选择, 排障用这个"
        echo "  debug    最详细, 仅短期排查"
        echo
        echo "排查完记得改回 warning, 免得日志刷爆磁盘"
        exit 0
    fi
    case $2 in
    none | error | warning | info | debug) ;;
    *)
        echo "无效日志级别: $2 (可选 none/error/warning/info/debug)"
        exit 1
        ;;
    esac
    command -v jq >/dev/null 2>&1 || {
        echo "缺少 jq, 无法修改配置"
        exit 1
    }
    # 改配置必须: 写临时文件 -> 自检 -> 原子替换, 避免改坏线上配置
    jq --arg lv "$2" '.log.loglevel = $lv' $conf >$conf.tmp 2>/dev/null || {
        echo "生成新配置失败"
        rm -f $conf.tmp
        exit 1
    }
    chmod 600 $conf.tmp
    $bin run -test -config $conf.tmp >/dev/null 2>&1 || {
        echo "新配置自检未通过, 已放弃修改"
        rm -f $conf.tmp
        exit 1
    }
    mv -f $conf.tmp $conf
    systemctl restart xray
    sleep 1
    if systemctl is-active -q xray; then
        echo "日志级别已设为 $2, 服务已重启; 查看日志: xray log"
    else
        echo "服务重启后异常, 请查看: journalctl -u xray -n 50"
        exit 1
    fi
    ;;
conn)
    command -v jq >/dev/null 2>&1 || {
        echo "缺少 jq, 无法读取监听端口"
        exit 1
    }
    port=$(jq -r '.inbounds[0].port // empty' $conf 2>/dev/null)
    [[ -z $port ]] && {
        echo "未能从 $conf 读到监听端口"
        exit 1
    }
    command -v ss >/dev/null 2>&1 || {
        echo "缺少 ss 命令(iproute2)"
        exit 1
    }
    echo "端口 $port 上的已建立连接:"
    ss -tn state established "sport = :$port" 2>/dev/null | awk 'NR>1 && $1=="ESTAB" {printf "  %-24s <- %s\n", $4, $5}'
    echo "共 $(ss -tn state established "sport = :$port" 2>/dev/null | grep -c ESTAB) 条"
    ;;
config)
    cat $conf
    ;;
test)
    $bin run -test -config $conf
    ;;
bbr)
    # 与安装脚本里的 bbr_check 逻辑保持一致(此文件为独立脚本, 不共享函数)
    echo "BBR 状态:"
    echo "  内核版本 : $(uname -r)"
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    cc=${cc//[[:space:]]/}
    avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null)
    qdisc=${qdisc//[[:space:]]/}
    echo "  当前算法 : ${cc:-读取失败}"
    echo "  可用算法 : ${avail:-读取失败}"
    echo "  队列算法 : ${qdisc:-读取失败}"
    if command -v ss >/dev/null 2>&1; then
        # 只看 Xray 监听端口上的连接 —— 改 sysctl 不会切换老连接, 这才是"我的隧道在用哪个"
        port=$(command -v jq >/dev/null 2>&1 && jq -r '.inbounds[0].port // empty' $conf 2>/dev/null)
        if [[ $port ]]; then
            real=$(ss -tin state established "sport = :$port" 2>/dev/null | grep -oE '\b(bbr2|bbr|cubic|reno|htcp|vegas|dctcp)\b' | head -1)
            [[ $real ]] && echo "  连接实测 : $real (端口 $port 上的已建立连接)" \
                || echo "  连接实测 : 端口 $port 上暂无已建立连接"
        else
            real=$(ss -tin 2>/dev/null | grep -oE '\b(bbr2|bbr|cubic|reno|htcp|vegas|dctcp)\b' | head -1)
            [[ $real ]] && echo "  连接实测 : $real (全部已建立连接, 未能读到监听端口)"
        fi
    fi
    if [[ $cc == bbr ]]; then
        echo "  => BBR 已开启"
        [[ $qdisc == fq || $qdisc == fq_codel ]] || echo "     注意: 队列算法建议设为 fq, 否则 BBR 效果会打折"
    else
        echo "  => BBR 未开启"
        echo "     修复: echo -e 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr' > /etc/sysctl.d/99-bbr.conf && sysctl -p /etc/sysctl.d/99-bbr.conf"
        echo "     若报错: 多为容器内 /proc/sys 只读, 或内核低于 4.9 不支持"
    fi
    ;;
update)
    arch=$(uname -m)
    case $arch in
    amd64 | x86_64) a=64 ;;
    *aarch64* | *armv8*) a=arm64-v8a ;;
    *) echo "不支持的架构: $arch" && exit 1 ;;
    esac
    tmp=$(mktemp -d) || exit 1
    trap 'rm -rf "$tmp"' EXIT
    url="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-$a.zip"
    echo "下载 $url"
    wget --no-check-certificate -t 3 -q -O $tmp/x.zip $url \
        && unzip -qo $tmp/x.zip -d $tmp \
        && [[ -f $tmp/xray ]] \
        && $tmp/xray version >/dev/null 2>&1 || {
        echo "更新失败"
        exit 1
    }
    # 先写临时文件再原子替换(mv), 直接 cp 覆盖运行中的二进制会 Text file busy
    cp -f $tmp/xray $bindir/xray.new && chmod +x $bindir/xray.new \
        && mv -f $bindir/xray.new $bin || {
        echo "更新失败"
        exit 1
    }
    for f in geoip.dat geosite.dat; do
        [[ -f $tmp/$f ]] && cp -f $tmp/$f $bindir/$f
    done
    systemctl restart xray
    sleep 1
    systemctl is-active xray >/dev/null 2>&1 \
        && echo "Xray 已更新: $($bin version | head -1)" \
        || {
            echo "已更新但服务启动异常, 请执行: journalctl -u xray -n 50"
            exit 1
        }
    ;;
uninstall)
    read -r -p "确认卸载 Xray? 输入 yes 继续: " ans
    [[ $ans == yes ]] || {
        echo "已取消"
        exit 0
    }
    systemctl stop xray &>/dev/null
    systemctl disable xray &>/dev/null
    rm -f /etc/systemd/system/xray.service
    rm -rf /etc/xray
    rm -f /usr/local/bin/xray
    systemctl daemon-reload
    echo "Xray 已卸载"
    ;;
*)
    usage
    ;;
esac
EOF
    chmod +x /usr/local/bin/xray
    msg ok "管理命令已安装: xray"
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
show_help() {
    cat <<HELP
用法: bash $0 [选项]
  -p, --port <port>          监听端口 (默认 443; 交互安装时未指定会提示输入)
  -s, --sni <domain>         指定 REALITY 伪装站点域名 (默认自动探测)
  -n, --name <name>          节点名称 (默认 VPS-REALITY)
  -v, --version <ver>        指定 Xray 版本, e.g. v25.1.1 (默认 latest)
  -x, --proxy <addr>         使用代理下载, e.g. -x http://127.0.0.1:2333
      --https-proxy          附加安装 HTTPS 正向代理 (https://user:pass@ip:port)
      --https-proxy-port <p> 指定 HTTPS 代理端口 (隐含 --https-proxy; 交互模式回车用随机端口)
  -h, --help                 显示此帮助

端口说明:
  多数 VPS 商家只在安全组里放行了少数端口, 请填你已放行的端口。
  交互终端下未指定 --port 时会提示输入(回车用 443), 端口被占用会重新询问;
  管道/CI 等非交互环境不提示, 直接用 --port 或默认 443。

示例:
  bash install-reality.sh
  bash install-reality.sh --port 8443 --sni www.microsoft.com --name 我的节点
  bash install-reality.sh --https-proxy --https-proxy-port 3128
HELP
    [[ ${1:-} ]] && exit "$1"
    exit 0
}

pass_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        -p | --port)
            [[ -z $2 ]] && err "($1) 缺少端口参数"
            [[ $2 =~ ^[0-9]+$ ]] && (( 10#$2 >= 1 && 10#$2 <= 65535 )) || err "端口无效: $2"
            port=$((10#$2))
            shift 2
            ;;
        -s | --sni)
            [[ -z $2 ]] && err "($1) 缺少 SNI 参数"
            valid_domain "$2" || err "SNI 域名格式无效: $2"
            sni_arg=$2
            shift 2
            ;;
        -n | --name)
            [[ -z $2 ]] && err "($1) 缺少节点名称参数"
            node_name=$2
            shift 2
            ;;
        -v | --version)
            [[ -z $2 ]] && err "($1) 缺少版本参数"
            core_ver="v${2#v}"
            shift 2
            ;;
        -x | --proxy)
            [[ -z $2 ]] && err "($1) 缺少代理参数, 示例: -x http://127.0.0.1:2333"
            proxy=$2
            shift 2
            ;;
        --https-proxy)
            hp_enabled=1
            shift
            ;;
        --https-proxy-port)
            [[ -z $2 ]] && err "($1) 缺少端口参数"
            [[ $2 =~ ^[0-9]+$ ]] && (( 10#$2 >= 1 && 10#$2 <= 65535 )) || err "端口无效: $2"
            hp_port=$((10#$2))
            hp_enabled=1
            shift 2
            ;;
        -h | --help)
            show_help
            ;;
        *)
            echo -e "\n${is_err} ($1) 为未知参数...\n"
            show_help 1
            ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
    [[ $# -gt 0 ]] && pass_args "$@"

    # 已安装检测
    [[ -f /etc/xray/bin/xray ]] && err "检测到 Xray 已安装, 如需重装请先执行: ${green}xray uninstall${none}"
    [[ -f /usr/local/bin/v2ray ]] && warn "检测到旧版 V2Ray, 建议先卸载旧 v2ray 再安装, 避免端口冲突"

    clear
    echo
    echo "........... Xray VLESS+REALITY 一键安装 ..........."
    echo

    msg warn "开始安装..."
    [[ $core_ver ]] && msg warn "Xray 版本: ${yellow}$core_ver${none}"
    [[ $proxy ]] && msg warn "使用代理: ${yellow}$proxy${none}"

    # 端口: --port 优先, 交互终端下提示输入(端口被占用会重新询问)
    # 放在依赖安装之前, 避免用户等着装依赖才被问
    ask_port

    # HTTPS 正向代理: 交互终端下询问, 非交互环境用 --https-proxy 启用
    ask_https_proxy

    # 时间同步 (失败仅警告, REALITY 不依赖精确时间, 但 TLS 需要)
    timedatectl set-ntp true &>/dev/null || warn "无法设置自动同步时间, 不影响 REALITY 使用, 但建议修复"

    # 依赖
    install_pkg wget unzip openssl
    install_jq

    # 下载 Xray
    download_core

    # 获取公网 IP
    msg warn "获取服务器 IP ..."
    get_ip
    [[ -z $ip ]] && err "获取服务器 IP 失败, 请检查网络"

    # 选定 SNI
    select_sni

    # 生成配置 + 自检 + 链接
    gen_config

    # 安装 systemd 服务并启动
    install_service

    # 防火墙放行
    if [[ $hp_enabled ]]; then
        open_firewall "$port" "$hp_port"
        # 商家安全组独立于系统防火墙, 脚本无法自动放行, 明确提示避免装完连不上
        msg warn "如你的 VPS 商家有安全组/防火墙面板, 请确认已放行 TCP 端口: $port $hp_port"
    else
        open_firewall "$port"
        msg warn "如你的 VPS 商家有安全组/防火墙面板, 请确认已放行 TCP 端口: $port"
    fi

    # BBR 优化
    enable_bbr

    # 管理命令
    install_cli

    # 输出节点信息
    echo
    printf '=%.0s' {1..78}
    echo
    cat $info_file
    printf '=%.0s' {1..78}
    echo
    msg ok "安装完成! 节点信息已保存到 $info_file"
    msg ok "日常管理: ${yellow}xray {start|stop|restart|status|info|log|loglevel|conn|config|test|bbr|update|uninstall}${none}"
    echo
}

main "$@"
