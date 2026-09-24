#!/bin/bash
#
# check-bbr.sh - 一条命令确认服务器是否开启了 BBR
#
# 用法:
#   bash check-bbr.sh
#   bash <(curl -fsSL https://raw.githubusercontent.com/<你的用户名>/xray-reality-installer/main/check-bbr.sh)
#
# 退出码: 0 = BBR 已开启; 1 = 未开启; 2 = 无法读取内核参数
# 只读 /proc/sys 与 /etc/sysctl.d, 不需要 root
#
# 判据说明:
#   net.ipv4.tcp_congestion_control == bbr        <- 只有这条能证明"已开启"
#   net.ipv4.tcp_available_congestion_control     <- 含 bbr 只说明"内核支持", 两者极易混淆

# 非终端(管道/重定向/写日志)时关闭颜色, 避免转义字符污染输出
if [[ -t 1 && -z $NO_COLOR ]]; then
    red=$'\e[31m'; yellow=$'\e[33m'; green=$'\e[92m'; gray=$'\e[90m'; cyan=$'\e[96m'; none=$'\e[0m'
else
    red=''; yellow=''; green=''; gray=''; cyan=''; none=''
fi

kver=$(uname -r 2>/dev/null)
# 拥塞控制与队列算法名不含空格, 去掉可能的空白后再比较
cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | tr -d '[:space:]')
qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null | tr -d '[:space:]')
# 可用算法是空格分隔的列表, 不能去掉空格
avail=$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)

echo
echo "${cyan}BBR 状态检查${none}  (主机: $(hostname 2>/dev/null || echo 未知))"
echo "----------------------------------------------------------"
printf '  内核版本 : %s%s%s\n' "$green" "${kver:-未知}" "$none"
printf '  当前算法 : %s%s%s\n' "$green" "${cc:-读取失败}" "$none"
printf '  可用算法 : %s%s%s\n' "$gray" "${avail:-未知}" "$none"
printf '  队列算法 : %s%s%s\n' "$gray" "${qdisc:-未知}" "$none"

# 持久化: sysctl 改的是运行时值, 没写进配置文件的话重启就丢
persist=$(grep -rslE '^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr' \
    /etc/sysctl.conf /etc/sysctl.d 2>/dev/null | head -1)
printf '  持久化   : %s\n' "${persist:-${yellow}未配置(重启后会失效)${none}}"

# 已建立的连接用的是建连时的算法, 改 sysctl 不会切换老连接,
# 所以这一行才代表"我的连接真的在用哪个"
if command -v ss >/dev/null 2>&1; then
    port=""
    if [[ -f /etc/xray/config.json ]] && command -v jq >/dev/null 2>&1; then
        port=$(jq -r '.inbounds[0].port // empty' /etc/xray/config.json 2>/dev/null)
    fi
    if [[ $port ]]; then
        real=$(ss -tin state established "sport = :$port" 2>/dev/null \
            | grep -oE '\b(bbr2|bbr|cubic|reno|htcp|vegas|dctcp)\b' | head -1)
        printf '  连接实测 : %s\n' "${real:-端口 $port 上暂无已建立连接}"
    else
        real=$(ss -tin 2>/dev/null | grep -oE '\b(bbr2|bbr|cubic|reno|htcp|vegas|dctcp)\b' | head -1)
        [[ $real ]] && printf '  连接实测 : %s\n' "$real (全部已建立连接; 老连接沿用建连时的算法, 与上面不一致属正常)"
    fi
fi

echo "----------------------------------------------------------"

if [[ -z $cc ]]; then
    echo "  ${red}=> 无法判断${none}"
    echo "     读不到 net.ipv4.tcp_congestion_control: 可能不是 Linux, 或 /proc/sys 不可访问"
    echo
    exit 2
fi

if [[ $cc == bbr ]]; then
    echo "  ${green}=> BBR 已开启${none}"
    [[ $qdisc == fq || $qdisc == fq_codel ]] || \
        echo "     注意: 队列算法建议设为 fq, 否则 BBR 效果会打折"
    [[ $persist ]] || echo "     注意: 未写入 sysctl 配置文件, 服务器重启后会退回默认算法"
    echo
    exit 0
fi

echo "  ${red}=> BBR 未开启${none}"
if [[ $avail != *bbr* ]]; then
    echo "     原因: 内核不支持 BBR(可用算法列表里没有 bbr), 需要内核 >= 4.9"
    echo "           若是 OpenVZ/LXC 等共享宿主内核的容器, 宿主机不换内核就无法开启"
else
    echo "     原因: 内核支持 BBR, 但当前默认算法是 ${cc}, 未启用"
fi
echo "     修复(root 执行, 立即生效且重启后保留):"
echo "       echo -e 'net.core.default_qdisc=fq\\nnet.ipv4.tcp_congestion_control=bbr' > /etc/sysctl.d/99-bbr.conf && sysctl -p /etc/sysctl.d/99-bbr.conf"
echo "     若报错: 多为容器内 /proc/sys 只读, 或内核低于 4.9"
echo
exit 1
