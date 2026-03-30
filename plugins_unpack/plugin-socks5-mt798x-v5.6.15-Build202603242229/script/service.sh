#!/bin/bash 
FEATURE_ID=5
ENABLE_FEATURE_CHECK=1
#IgnoreCheck-All$0

# clash连路表
# iptables -t nat -L shellcrash -n -v --line-numbers
# iptables -t nat -L shellcrash_dns -n -v --line-numbers
# iptables -t mangle -L shellcrash_mark -n -v --line-numbers
# iptables -t mangle -C shellcrash_mark -p tcp --dport 53 -j RETURN
# iptables -t mangle -C shellcrash_mark -p udp --dport 53 -j RETURN
# iptables -I FORWARD -i lan1 -o lan1 -j DROP
# ip6tables -t nat -L shellcrashv6 -n -v --line-numbers
# ip6tables -t nat -L shellcrashv6_dns -n -v --line-numbers
# ip6tables -t mangle -L shellcrashv6_mark -n -v --line-numbers
# ip6tables -t mangle -L shellcrash_mark -n -v --line-numbers
# ip6tables -D INPUT -p tcp --dport 7890 -j REJECT --reject-with icmp6-port-unreachable

. /etc/release
. /usr/ikuai/include/interface.sh
. /etc/mnt/plugins/configs/config.sh

[ "$ARCH" = "mips" ] && platform="mt7621"
[ "$ARCH" = "arm" ] && platform="mt798x"
[ "$ARCH" = "x86" ] && platform="x86"

PLUGIN_NAME="socks5"
CHROOTDIR=$(chrootmgt get_chroot_dir)
CRASHDIR=$EXT_PLUGIN_INSTALL_DIR/$PLUGIN_NAME/bin
LOGFILE=$EXT_PLUGIN_LOG_DIR/$PLUGIN_NAME/log.txt
ADV_SETTINGFILE=$CRASHDIR/configs/adv_settings.sh
. $CRASHDIR/configs/ShellCrash.cfg

# 工具类方法
debug() {
    debuglog=$([ -s /tmp/debug_on ] && cat /tmp/debug_on || echo -n /tmp/debug.log)
    if [ "$1" = "clear" ]; then
        rm -f $debuglog && return
    fi

    if [ -f /tmp/debug_on ]; then
        TIME_STAMP=$(date +"%Y%m%d %H:%M:%S")
        echo "[$TIME_STAMP]: PL> $1" >>$debuglog
    fi
}
sanitize_file() {
    local target="$1"
    local dir tmp

    dir="$(dirname "$target")"
    tmp="$(mktemp "$dir/.tmp.XXXXXX")" || return 1

    if tr -d '\000' <"$target" >"$tmp" 2>/dev/null; then
        mv -f "$tmp" "$target"
    else
        rm -f "$tmp"
        return 1
    fi
}
format_bytes() {
    local bytes=$1
    local unit=""
    local value=0

    if [ "$bytes" -ge 1099511627776 ]; then
        unit="TB"
        value=$((bytes * 10 / 1099511627776))
    elif [ "$bytes" -ge 1073741824 ]; then
        unit="GB"
        value=$((bytes * 10 / 1073741824))
    elif [ "$bytes" -ge 1048576 ]; then
        unit="MB"
        value=$((bytes * 10 / 1048576))
    elif [ "$bytes" -ge 1024 ]; then
        unit="KB"
        value=$((bytes * 10 / 1024))
    else
        echo "${bytes} B"
        return
    fi

    int_part=$((value / 10))
    decimal_part=$((value % 10))
    echo "${int_part}.${decimal_part} ${unit}"
}

# 服务启动停止控制相关方法
boot() {

    isAdv=$(authtool check-plugin 6 >/dev/null 2>&1 && echo "true" || echo "false")

    # 设置最大打开文件数
    memsize=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    if [ "$isAdv" != "true" ]; then
        sysctl -w fs.file-max=15000 >/dev/null 2>&1
        ulimit -n 10240 >/dev/null 2>&1
    else
        if [ "$memsize" -gt 3800000 ]; then
            sysctl -w fs.file-max=655350 >/dev/null 2>&1
            ulimit -n 327680 >/dev/null 2>&1
        elif [ "$memsize" -gt 1000000 ]; then
            sysctl -w fs.file-max=150000 >/dev/null 2>&1
            ulimit -n 100000 >/dev/null 2>&1
        else
            sysctl -w fs.file-max=65535 >/dev/null 2>&1
            ulimit -n 32768 >/dev/null 2>&1
        fi
    fi

    if [ "$isAdv" != "true" ] || [ ! -f "$ADV_SETTINGFILE" ]; then
        printf '' >"$ADV_SETTINGFILE"
    fi

    defaultAdvSettings=(
        "denyLocalNet=0"
        "denyVideoData=0"
        "tcpOptimization=0"
        "connTestSite=4"
        "disableUdp=0"
        "domainSniffing=0"
        "tunmode=0"
        "dnsmode=\"none\""
        "nodeGroupType=\"disabled\""
        "rejectQUIC=0"
        "bypassCNIP=0"
        "networkMonitoring=0"
        "detection=0"
        "dnsResolveNodes=\"\""
    )

    for advSetting in "${defaultAdvSettings[@]}"; do
        kname="${advSetting%%=*}"
        if ! grep -q "^$kname=" "$ADV_SETTINGFILE" 2>/dev/null; then
            echo "$advSetting" >>"$ADV_SETTINGFILE"
        fi
    done

    . "$ADV_SETTINGFILE"

}
start() {

    firmwareVer=$(authtool version)
    if [ "$firmwareVer" -lt "202507100000" ]; then
        echo "当前定制固件版本过低！需升级获得最佳安全及稳定性, 请至作者云盘下载最新版固件！"
        return 1
    fi

    if [ -d "$EXT_PLUGIN_INSTALL_DIR/clash" ] || [ -d "$EXT_PLUGIN_INSTALL_DIR/Clash" ]; then
        echo "本插件和“小猫咪”插件不兼容！请先卸载小猫咪再启动本插件！"
        return 1
    fi

    debug "开始启动SK5服务..."
    sanitize_file "$ADV_SETTINGFILE"
    sanitize_file "$CRASHDIR/yamls/rules.yaml"
    sanitize_file "$CRASHDIR/yamls/proxies.yaml"

    handel_adv_settings
    monitor_tcp_traffic start

    pidof CrashCore >/dev/null && stop
    startCrashCore
    startInnerDNS

    # 检查启动是否成功
    i=1
    db_port=$(cat $CRASHDIR/configs/ShellCrash.cfg | grep "hostdir" | cut -d ':' -f2 | cut -d '/' -f1)
    while [ -z "$test" -a "$i" -lt 5 ]; do
        sleep 1
        test=$(curl -s http://127.0.0.1:${db_port}/configs --header "Authorization: Bearer $secret" | grep -o port)
        [ -n "$test" ] && break
        i=$((i + 1))
    done

    local ret=1
    if [ -n "$test" -o -n "$(pidof CrashCore)" ]; then
        ret=0
        patch_all_config || ret=1
        reload_config || ret=1
        add_guard_task || ret=1
        clear_connections
        create_custom_iprules &
    fi

    if [ "$ret" -eq "0" ]; then
        touch $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/autostart
        debug "SK5服务启动成功"
        echo "启动成功"
        return 0
    else
        debug "SK5服务启动失败"
        return 1
    fi

}
stop() {

    pidof CrashCore >/dev/null || return 0

    stopCrashCore
    stopInnerDNS
    monitor_tcp_traffic stop
    remove_guard_task

    Vmen=0 success=0
    while true; do
        sleep 1
        pidof CrashCore >/dev/null || {
            success=1
            break
        }

        Vmen=$((Vmen + 1))
        [ $Vmen -gt 30 ] && break
    done

    if [ $success -eq 1 ]; then
        debug "SK5服务已停止"
        rm $CHROOTDIR/tmp/ShellCrash -rf
        rm $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/autostart
        return 0
    else
        debug "SK5服务停止失败"
        echo "停止Clash失败！"
        return 1
    fi
}
startCrashCore() {

    # 生成ip_filter白名单配置文件
    if grep -qE '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' "$CRASHDIR/yamls/rules.yaml"; then
        awk -F'[,]' '{print $2}' $CRASHDIR/yamls/rules.yaml | sort -u >$CRASHDIR/configs/ip_filter
    else
        # 插入一条保留IP地址（内网通常不会有）到白名单，初始化白名单相关配置
        echo "203.0.113.1" >$CRASHDIR/configs/ip_filter
    fi

    # 不加载rules和proxies配置，因为启动后还需要处理后重新加载
    mv -f $CRASHDIR/yamls/rules.yaml $CRASHDIR/yamls/rules.yaml.bk
    mv -f $CRASHDIR/yamls/proxies.yaml $CRASHDIR/yamls/proxies.yaml.bk

    # 阻止Tun内核劫持全部dns请求,让远程DNS有机会接管, 必须在启动前修改好才生效
    if [ "$dnsmode" = "remotedns" ]; then
        if ! grep -q "dns-hijack" $CRASHDIR/start.sh; then
            sed -i 's/auto-detect-interface: false/auto-detect-interface: false, dns-hijack: [tcp:\/\/203.0.113.1:53]/g' $CRASHDIR/start.sh
        fi
    fi

    # Chroot下启动CrashCore
    ps | grep socks5/bin/menu.sh | grep -v grep | awk '{print $1}' | xargs -r kill -9
    chrootmgt run "$CRASHDIR/menu.sh -s start >/dev/null"

    mv -f $CRASHDIR/yamls/rules.yaml.bk $CRASHDIR/yamls/rules.yaml
    mv -f $CRASHDIR/yamls/proxies.yaml.bk $CRASHDIR/yamls/proxies.yaml

    # 还原start.sh配置
    sed -i 's/, dns-hijack: \[tcp:\/\/203\.0\.113\.1:53\]//g' $CRASHDIR/start.sh
}
stopCrashCore() {
    ps | grep socks5/bin/menu.sh | grep -v grep | awk '{print $1}' | xargs -r kill -9
    chrootmgt run "$CRASHDIR/menu.sh -s stop >/dev/null"
}
startInnerDNS() {
    if [ "$dnsmode" = "interdnspro" ]; then
        if pid=$(cat /var/run/pldnsd.pid 2>/dev/null); then
            kill $pid >/dev/null 2>/dev/null
        fi
        ik_cntl dns-cache disable
        ln -s /usr/sbin/ikdnsd /usr/sbin/pldnsd
        pldnsd -C $CRASHDIR/configs/pldnsd.cfg -P /var/run/pldnsd.pid
    fi
}
stopInnerDNS() {
    if pid=$(cat /var/run/pldnsd.pid 2>/dev/null); then
        kill $pid >/dev/null 2>/dev/null
    fi
}
restart() {
    local ret=0
    if killall -q -0 CrashCore; then

        stopCrashCore
        stopInnerDNS
        startCrashCore
        startInnerDNS

        patch_all_config || ret=1
        reload_config || ret=1
        clear_connections
        create_custom_iprules &
    fi

    if [ $ret -eq 0 ]; then
        debug "SK5服务已重启"
        return 0
    else
        debug "SK5服务重启失败"
        return 1
    fi
}

reload_config() {
    if killall -q -0 CrashCore; then
        msg=$(curl -X PUT "http://127.0.0.1:9999/configs" -d '{"path": "/tmp/ShellCrash/config.yaml"}' --header "Authorization: Bearer $secret")
        if [ -n "$msg" ]; then
            echo "$msg" >>$LOGFILE
            message=$(echo "$msg" | jq -r '.message')
            echo "配置文件加载出错：$message"
            return 1
        else
            return 0
        fi
    fi
}
clear_connections() {

    # if [ -n "${1}" ]; then
    # 	address_ip="${1}"
    # 	conntrack -D -s "${address_ip%/*}" >/dev/null 2>&1
    # else
    # 	for address_ip in $(cat $CRASHDIR/configs/ip_filter); do
    # 		conntrack -D -s "${address_ip%/*}" >/dev/null 2>&1
    # 	done
    # fi
    # return 0

    pidof CrashCore >/dev/null 2>&1 || return 0
    if [ -n "$1" ]; then
        SOURCE_IP=${1%/*}
        connections=$(curl -s "http://127.0.0.1:9999/connections" --header "Authorization: Bearer $secret")
        connection_ids=$(echo "$connections" | jq -r --arg ip "$SOURCE_IP" '.connections[] | select(.metadata.sourceIP == $ip) | .id')
    else
        connections=$(curl -s "http://127.0.0.1:9999/connections" --header "Authorization: Bearer $secret")
        connection_ids=$(echo "$connections" | jq -r '.connections[] | .id')
    fi

    if [ -n "$connection_ids" ]; then
        for id in $connection_ids; do
            curl -X DELETE "http://127.0.0.1:9999/connections/$id" --header "Authorization: Bearer $secret" >/dev/null 2>&1
        done
    fi

}
clear_connections_byserver() {
    local name=$1
    if [ -n "$name" ]; then
        [[ $name != iKuai_* ]] && name="iKuai_$name"
        grep ",$name" $CRASHDIR/yamls/rules.yaml | cut -d ',' -f 2 2>/dev/null | while read -r ip_address; do
            [ -n "$ip_address" ] && clear_connections "$ip_address"
        done
    else
        clear_connections
    fi
}
patch_server_config() {
    pidof CrashCore >/dev/null 2>&1 || return 0
    # 修正服务节点配置,无节点启动时proxies：配置节会被自动删除
    if ! grep -q "^proxies:" $CHROOTDIR/tmp/ShellCrash/config.yaml; then
        sed -i '/^proxy-groups:/i\proxies:' $CHROOTDIR/tmp/ShellCrash/config.yaml
    fi
    # 根据高级设置确定测速URL
    local test_url=""
    case "$connTestSite" in
    1) test_url="https://www.gstatic.com/generate_204" ;;
    2) test_url="http://captive.apple.com/hotspot-detect.html" ;;
    3) test_url="http://www.msftconnecttest.com/connecttest.txt" ;;
    *) test_url="http://connect.rom.miui.com/generate_204" ;;
    esac

    # 根据proxies.yaml重建节点配置
    sed -i "/name: iKuai_/d" $CHROOTDIR/tmp/ShellCrash/config.yaml

    awk '{
		# 缩进处理
		sub(/^/, "  ")
		# 识别并对关键字段的值加引号（如果尚未加引号）
		# 目标 Key: username, password, cipher, sni, uuid, auth, token, interface-name, dialer-proxy
		split("username password cipher sni uuid auth token interface-name dialer-proxy", keys)
		for (i in keys) {
			k = keys[i] ":"
			# 匹配模式：key: 后面跟着非引号开头的值
			reg = k "[[:space:]]*[^\"{\x27][^,}]*"
			if (match($0, reg)) {
				# 准确定位值的起始和结束位置
				match($0, k "[[:space:]]*")
				val_start = RSTART + RLENGTH
				tail = substr($0, val_start)
				match(tail, /[^,}]*/)
				val = substr(tail, 1, RLENGTH)
				# 清理尾部空格
				raw_val = val
				gsub(/[[:space:]]+$/, "", raw_val)
				if (length(raw_val) > 0) {
					new_val = "\"" raw_val "\""
					$0 = substr($0, 1, val_start-1) new_val substr($0, val_start + length(val))
				}
			}
		}
		print $0
	}' "$CRASHDIR/yamls/proxies.yaml" >/tmp/proxies_indented1
    sed -i "/^proxies:/r /tmp/proxies_indented1" $CHROOTDIR/tmp/ShellCrash/config.yaml

    # 根据高级配置打开或关闭节点的tfo功能
    if [ "$tcpOptimization" = "0" ]; then
        sed -i "s/tfo: true/tfo: false/g" $CHROOTDIR/tmp/ShellCrash/config.yaml
    else
        sed -i "s/tfo: false/tfo: true/g" $CHROOTDIR/tmp/ShellCrash/config.yaml
    fi

    # 根据高级配置打开或关闭节点的UDP功能
    if [ "$disableUdp" = "1" ]; then
        sed -i "s/udp: true/udp: false/g" $CHROOTDIR/tmp/ShellCrash/config.yaml
    else
        sed -i "s/udp: false/udp: true/g" $CHROOTDIR/tmp/ShellCrash/config.yaml
    fi

    # 根据proxies.yaml重建all-proxies节点组及自动生成代理组 (动态策略)
    local aggreg_tmp="/tmp/aggreg_tmp"

    local proxyGroupType="disabled"
    [ "$nodeGroupType" = "fastest" ] && proxyGroupType="url-test"
    [ "$nodeGroupType" = "fallback" ] && proxyGroupType="fallback"
    [ "$nodeGroupType" = "balance" ] && proxyGroupType="load-balance"

    awk -v p_type="$proxyGroupType" -v t_url="$test_url" '
		{
			if ($0 == "" || $0 ~ /^[[:space:]]*$/) next
			line = $0
			sub(/^[[:space:]]*-[[:space:]]*/, "", line)
			sub(/^\{/, "", line)
			sub(/\}$/, "", line)

			name=""; group=""
			n = split(line, fields, /,[[:space:]]*/)
			for (i=1; i<=n; i++) {
				split(fields[i], kv, /:[[:space:]]*/)
				key = kv[1]
				val = fields[i]
				sub(/[^:]+:[[:space:]]*/, "", val)
				gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
				gsub(/^["\x27]|["\x27]$/, "", val)

				if (key == "name") name = val
				else if (key == "ik_group") group = val
			}
			if (name != "") {
				all_nodes = (all_nodes == "" ? "" : all_nodes ",") "\x27" name "\x27"
				if (group != "") {
					groups[group] = (groups[group] == "" ? "" : groups[group] ",") "\x27" name "\x27"
				}
			}
		}
		END {
			# 输出 all-proxies 信息作为第一行，后续为分组信息
			print all_nodes
			if (p_type != "disabled") {
				for (g in groups) {
					printf "  - name: iKuai_Group_%s\n    type: %s\n    url: %s\n    interval: 300\n    tolerance: 50\n    proxies: [%s]\n", g, p_type, t_url, groups[g]
				}
			}
		}
	' "$CRASHDIR/yamls/proxies.yaml" >"$aggreg_tmp" 2>/dev/null

    # 1. 准备核心数据
    local all_proxies=$(head -n 1 "$aggreg_tmp")
    [ -n "$all_proxies" ] || all_proxies="'DIRECT'"
    local groups_block="/tmp/groups_block"
    tail -n +2 "$aggreg_tmp" >"$groups_block"

    # 根据高级设置中的DNS解析节点设置，重建dns-proxies节点组，用于dns解析
    local dns_proxies=""
    if [ -z "$dnsResolveNodes" -o "$dnsResolveNodes" = "auto" ]; then
        dns_proxies=$all_proxies
    else
        for node in $(echo "$dnsResolveNodes" | tr ',' '\n'); do
            if grep -q "name: iKuai_${node}," $CRASHDIR/yamls/proxies.yaml; then
                dns_proxies+="${dns_proxies:+,}'iKuai_$node'"
            fi
        done
    fi
    # 其它地方也会用到dns_proxies，所以为了简化，注释下面这行不再判断
    # [ -z "$dns_proxies" -o "$dnsmode" != "localdns" ] && dns_proxies="'DIRECT'"

    # 2. 原子化重建 proxy-groups 相关章节 (扫除残留垃圾)
    # 该脚本会寻找 all-proxies, dns-proxies 以及 iKuai_Group_ 开头的组，
    # 并在遇到它们时吃掉其后的所有非 - name: 行，然后重新打印正确的配置。
    awk -v