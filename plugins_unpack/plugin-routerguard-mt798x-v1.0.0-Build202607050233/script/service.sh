#!/bin/bash 
FEATURE_ID=0
ENABLE_FEATURE_CHECK=1
PLUGIN_NAME="routerguard"
CHAIN="routerguard_input"
CHAIN6_INPUT="routerguard6_input"
CHAIN6_FORWARD="routerguard6_forward"
PENDING_SECONDS=180

. /etc/mnt/plugins/configs/config.sh

if [ -n "$ikuai_script" ] && [ -r "$ikuai_script/include/get_ipmac.sh" ]; then
	. "$ikuai_script/include/get_ipmac.sh" 2>/dev/null
fi

CONFIG_DIR="$EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME"
CONFIG_FILE="$CONFIG_DIR/config"
PENDING_FILE="$CONFIG_DIR/pending"
IPV6_STATE_FILE="$CONFIG_DIR/ipv6_state"
LOG_FILE="$EXT_PLUGIN_LOG_DIR/$PLUGIN_NAME.log"

log_msg()
{
	[ -d "$EXT_PLUGIN_LOG_DIR" ] || mkdir -p "$EXT_PLUGIN_LOG_DIR"
	echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

ensure_config_dir()
{
	[ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR"
}

default_config()
{
	enabled=0
	allowIp=""
	allowMac=""
	dropPolicy="DROP"
	disableIpv6=1
}

load_config()
{
	default_config
	[ -f "$CONFIG_FILE" ] && . "$CONFIG_FILE"
}

is_ipv4()
{
	local ip="$1"
	echo "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
	local a b c d
	IFS=. read -r a b c d <<EOF
$ip
EOF
	for n in "$a" "$b" "$c" "$d"; do
		[ "$n" -ge 0 ] 2>/dev/null && [ "$n" -le 255 ] 2>/dev/null || return 1
	done
	return 0
}

is_mac()
{
	[ -n "$1" ] || return 1
	echo "$1" | grep -Eiq '^([0-9a-f]{2}:){5}[0-9a-f]{2}$'
}

normalize_ifaces()
{
	echo "$1" | tr ',，' '  ' | tr -cs 'A-Za-z0-9_.:-' ' ' | sed 's/^ *//;s/ *$//'
}

save_config_file()
{
	ensure_config_dir
	cat > "$CONFIG_FILE" <<EOF
enabled=$enabled
allowIp="$allowIp"
allowMac="$allowMac"
dropPolicy="$dropPolicy"
disableIpv6=$disableIpv6
EOF
}

validate_config()
{
	[ "$enabled" = "1" ] || return 0

	if ! is_ipv4 "$allowIp"; then
		echo "可信管理 IP 不是合法 IPv4 地址"
		return 1
	fi

	if [ -n "$allowMac" ] && ! is_mac "$allowMac"; then
		echo "可信管理 MAC 获取失败"
		return 1
	fi

	case "$dropPolicy" in
	DROP|REJECT) ;;
	*) dropPolicy="DROP" ;;
	esac

	case "$disableIpv6" in
	1|true) disableIpv6=1 ;;
	*) disableIpv6=0 ;;
	esac
	return 0
}

get_trusted_mac()
{
	local ip="$1"
	local mac=""

	[ -n "$ip" ] || return 1

	if declare -F get_ipmac >/dev/null 2>&1; then
		mac="$(get_ipmac "$ip" 2>/dev/null | tr -d '[:space:]')"
	fi

	if ! is_mac "$mac" && command -v ip >/dev/null 2>&1; then
		mac="$(ip neigh show "$ip" 2>/dev/null | awk '
			{
				for (i = 1; i <= NF; i++) {
					if ($i == "lladdr" && (i + 1) <= NF) {
						print $(i + 1)
						exit
					}
				}
			}
		')"
	fi

	if ! is_mac "$mac" && command -v arp >/dev/null 2>&1; then
		mac="$(arp -n 2>/dev/null | awk -v ip="$ip" '$1 == ip {print $3; exit}')"
	fi

	if ! is_mac "$mac" && [ -r /proc/net/arp ]; then
		mac="$(awk -v ip="$ip" '$1 == ip {print $4; exit}' /proc/net/arp 2>/dev/null)"
	fi

	if is_mac "$mac"; then
		echo "$mac" | tr 'a-f' 'A-F'
		return 0
	fi

	return 1
}

prepare_trusted_source()
{
	if [ -z "$allowIp" ]; then
		allowIp="${IKREST_REMOTE_ADDR:-}"
	fi

	allowMac="$(echo "${allowMac:-}" | tr 'a-f' 'A-F')"
}

clear_ipv6_guard()
{
	if command -v ip6tables >/dev/null 2>&1; then
		while ip6tables -D INPUT -j "$CHAIN6_INPUT" 2>/dev/null; do :; done
		while ip6tables -D FORWARD -j "$CHAIN6_FORWARD" 2>/dev/null; do :; done
		ip6tables -F "$CHAIN6_INPUT" 2>/dev/null
		ip6tables -X "$CHAIN6_INPUT" 2>/dev/null
		ip6tables -F "$CHAIN6_FORWARD" 2>/dev/null
		ip6tables -X "$CHAIN6_FORWARD" 2>/dev/null
	fi

	if [ -f "$IPV6_STATE_FILE" ]; then
		while IFS='=' read -r key value; do
			[ -n "$key" ] || continue
			[ -e "/proc/sys/net/ipv6/conf/$key/disable_ipv6" ] || continue
			echo "$value" > "/proc/sys/net/ipv6/conf/$key/disable_ipv6" 2>/dev/null
		done < "$IPV6_STATE_FILE"
		rm -f "$IPV6_STATE_FILE"
	fi
}

apply_ipv6_guard()
{
	[ "$disableIpv6" = "1" ] || return 0
	ensure_config_dir

	if [ ! -f "$IPV6_STATE_FILE" ]; then
		{
			[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && echo "all=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)"
			[ -e /proc/sys/net/ipv6/conf/default/disable_ipv6 ] && echo "default=$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6)"
		} > "$IPV6_STATE_FILE"
	fi

	echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null
	echo 1 > /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null

	if command -v ip6tables >/dev/null 2>&1; then
		while ip6tables -D INPUT -j "$CHAIN6_INPUT" 2>/dev/null; do :; done
		while ip6tables -D FORWARD -j "$CHAIN6_FORWARD" 2>/dev/null; do :; done
		ip6tables -N "$CHAIN6_INPUT" 2>/dev/null
		ip6tables -F "$CHAIN6_INPUT" 2>/dev/null
		ip6tables -A "$CHAIN6_INPUT" -j DROP 2>/dev/null
		ip6tables -I INPUT 1 -j "$CHAIN6_INPUT" 2>/dev/null
		ip6tables -N "$CHAIN6_FORWARD" 2>/dev/null
		ip6tables -F "$CHAIN6_FORWARD" 2>/dev/null
		ip6tables -A "$CHAIN6_FORWARD" -j DROP 2>/dev/null
		ip6tables -I FORWARD 1 -j "$CHAIN6_FORWARD" 2>/dev/null
	fi
}

clear_guard()
{
	while iptables -D INPUT -j "$CHAIN" 2>/dev/null; do :; done
	iptables -F "$CHAIN" 2>/dev/null
	iptables -X "$CHAIN" 2>/dev/null
	clear_ipv6_guard
	rm -f "$PENDING_FILE"
	log_msg "routerguard cleared"
}

add_established_rule()
{
	iptables -A "$CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN 2>/dev/null && return 0
	iptables -A "$CHAIN" -m state --state ESTABLISHED,RELATED -j RETURN 2>/dev/null
}

add_lan_rules()
{
	# LAN DHCP: keep address assignment working for clients.
	iptables -A "$CHAIN" -m ifaces --ifaces lan*,vlan* --dir in -p udp --sport 68 --dport 67 -j RETURN 2>/dev/null

	# LAN DNS: keep router-side DNS service available to LAN clients.
	iptables -A "$CHAIN" -m ifaces --ifaces lan*,vlan* --dir in -p udp --dport 53 -j RETURN 2>/dev/null
	iptables -A "$CHAIN" -m ifaces --ifaces lan*,vlan* --dir in -p tcp --dport 53 -j RETURN 2>/dev/null

	# SoloIP LAN data-plane ports.
	iptables -A "$CHAIN" -m ifaces --ifaces lan*,vlan* --dir in -p tcp -m multiport --dports 7890,7892,7893,1053 -j RETURN 2>/dev/null
	iptables -A "$CHAIN" -m ifaces --ifaces lan*,vlan* --dir in -p udp -m multiport --dports 7890,7892,7893,1053 -j RETURN 2>/dev/null

	# Trusted management endpoint: only 80/443/9999.
	if [ -n "$allowMac" ]; then
		iptables -A "$CHAIN" -m ifaces --ifaces lan*,vlan* --dir in -s "$allowIp" -m mac --mac-source "$allowMac" -p tcp -m multiport --dports 80,443,9999 -j RETURN 2>/dev/null
	else
		iptables -A "$CHAIN" -m ifaces --ifaces lan*,vlan* --dir in -s "$allowIp" -p tcp -m multiport --dports 80,443,9999 -j RETURN 2>/dev/null
	fi
}

add_soloip_isolation_rules()
{
	# DHCP requests can arrive before an isolated client owns an address.
	iptables -A "$CHAIN" -i si_iso+ -p udp --sport 68 --dport 67 -j RETURN 2>/dev/null

	# Keep the isolated data plane usable without opening router management ports.
	iptables -A "$CHAIN" -i si_iso+ -p udp --dport 53 -j RETURN 2>/dev/null
	iptables -A "$CHAIN" -i si_iso+ -p tcp --dport 53 -j RETURN 2>/dev/null
	iptables -A "$CHAIN" -i si_iso+ -p tcp -m multiport --dports 7890,7892,7893,1053 -j RETURN 2>/dev/null
	iptables -A "$CHAIN" -i si_iso+ -p udp -m multiport --dports 7890,7892,7893,1053 -j RETURN 2>/dev/null
}

apply_guard()
{
	load_config
	enabled=1
	if ! validate_config; then
		return 1
	fi

	clear_guard
	iptables -N "$CHAIN" 2>/dev/null
	iptables -F "$CHAIN" 2>/dev/null

	iptables -A "$CHAIN" -i lo -j RETURN 2>/dev/null
	add_established_rule

	# WAN DHCP client replies: keep the router able to renew its upstream lease.
	iptables -A "$CHAIN" -p udp --sport 67 --dport 68 -j RETURN 2>/dev/null

	add_lan_rules
	add_soloip_isolation_rules

	iptables -A "$CHAIN" -j "$dropPolicy" 2>/dev/null
	if ! iptables -I INPUT 1 -j "$CHAIN" 2>/dev/null; then
		echo "无法挂载 INPUT 防护链"
		clear_guard
		return 1
	fi

	apply_ipv6_guard
	log_msg "routerguard applied: allowIp=$allowIp allowMac=$allowMac policy=$dropPolicy"
	return 0
}

rollback_if_unconfirmed()
{
	local token="$1"
	(
		sleep "$PENDING_SECONDS"
		if [ -f "$PENDING_FILE" ] && grep -q "^$token|" "$PENDING_FILE" 2>/dev/null; then
			load_config
			enabled=0
			save_config_file
			clear_guard
			log_msg "routerguard auto rollback: confirmation timeout"
		fi
	) >/dev/null 2>&1 &
}

save()
{
	ensure_config_dir
	enabled="${enabled:-0}"
	[ "$enabled" = "true" ] && enabled=1
	[ "$enabled" = "1" ] || enabled=0
	allowIp="${allowIp:-${IKREST_REMOTE_ADDR:-}}"
	allowMac="${allowMac:-}"
	dropPolicy="${dropPolicy:-DROP}"
	disableIpv6="${disableIpv6:-1}"

	prepare_trusted_source
	if ! validate_config; then
		return 1
	fi
	save_config_file
	return 0
}

save_apply()
{
	enabled=1
	if ! save; then
		return 1
	fi
	if ! apply_guard; then
		enabled=0
		save_config_file
		return 1
	fi

	local token
	local deadline
	token="$(date +%s)-$$"
	deadline="$(( $(date +%s) + PENDING_SECONDS ))"
	echo "$token|$deadline" > "$PENDING_FILE"
	rollback_if_unconfirmed "$token"
	echo "防护规则已应用，请在 ${PENDING_SECONDS} 秒内点击确认，否则将自动回滚"
	return 0
}

confirm()
{
	if [ ! -f "$PENDING_FILE" ]; then
		echo "当前没有待确认的防护规则"
		return 1
	fi
	rm -f "$PENDING_FILE"
	load_config
	enabled=1
	save_config_file
	log_msg "routerguard confirmed"
	return 0
}

start()
{
	load_config
	if [ "$enabled" != "1" ]; then
		echo "防护未启用"
		return 0
	fi
	apply_guard
}

stop()
{
	load_config
	enabled=0
	save_config_file
	clear_guard
	return 0
}

chain_active()
{
	iptables -C INPUT -j "$CHAIN" 2>/dev/null
}

show()
{
	Show __json_result__
}

__show_config()
{
	load_config
	local active=0
	local pending=0
	local pendingLeft=0
	local ipv6Disabled=0
	chain_active && active=1
	if [ -f "$PENDING_FILE" ]; then
		local pendingLine token deadline now
		pendingLine="$(cat "$PENDING_FILE" 2>/dev/null)"
		token="${pendingLine%%|*}"
		if echo "$pendingLine" | grep -q '|'; then
			deadline="${pendingLine#*|}"
		else
			deadline=""
		fi
		now="$(date +%s)"
		pending=1
		if [ -n "$deadline" ] && [ "$deadline" -gt 0 ] 2>/dev/null; then
			pendingLeft=$((deadline - now))
			[ "$pendingLeft" -gt 0 ] 2>/dev/null || pendingLeft=0
		fi
	fi
	[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ] && ipv6Disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)

	if [ -z "$allowIp" ]; then
		allowIp="${IKREST_REMOTE_ADDR:-}"
	fi
	if [ -z "$allowMac" ] && [ -n "$allowIp" ]; then
		allowMac="$(get_trusted_mac "$allowIp" 2>/dev/null || true)"
	fi
	allowMac="$(echo "${allowMac:-}" | tr 'a-f' 'A-F')"

	json_append __json_result__ enabled:int
	json_append __json_result__ active:int
	json_append __json_result__ pending:int
	json_append __json_result__ pendingLeft:int
	json_append __json_result__ allowIp:str
	json_append __json_result__ allowMac:str
	json_append __json_result__ dropPolicy:str
	json_append __json_result__ disableIpv6:int
	json_append __json_result__ ipv6Disabled:int
}


Command()
{

    if [ ! "$1" ];then
        return 0
    fi
    if ! declare -F "$1" >/dev/null 2>&1 ;then
        echo "unknown command ($1)"
        return 1
    fi

    local i
    for i in "${@:2}" ;do
        if [[ "$i" =~ ^([^=]+)=(.*) ]];then
            # 将值赋给以键命名的变量
            eval "${BASH_REMATCH[1]}='${BASH_REMATCH[2]}'"
        fi
    done

    $@
}

declare -A ___INCLUDE_ALREADY_LOAD_FILE___
declare -A ___JSON_ALREADY_LOAD_FILE___
declare -A ___I18N_ALREADY_LOAD_FILE___
declare -A CONVERT_NETMASK_TO_BIT
declare -A CHECK_IS_SETING
declare -A APPIDS
declare -A VERSION_ALL
declare -A SYSSTAT_MEM
declare -A SYSSTAT_STREAM
declare -A IK_HOSTS_UPDATE

LINE_R=$'\r'
LINE_N=$'\n'
LINE_RN=$'\r\n'
LINE_NT=$'\n\t'

IK_DIR_CONF=/etc/mnt/ikuai
IK_DIR_DATA=/etc/mnt/data
IK_DIR_BAK=/etc/mnt/bak
IK_DIR_LOG=/etc/log
IK_DIR_SCRIPT=/usr/ikuai/script
IK_DIR_INCLUDE=/usr/ikuai/include
IK_DIR_FUNCAPI=/usr/ikuai/function
IK_DIR_LIBPROTO=/usr/libproto
IK_DIR_TMP=/tmp/iktmp
IK_DIR_CACHE=/tmp/iktmp/cache
IK_DIR_LANG=/tmp/iktmp/LANG
IK_DIR_I18N=/etc/i18n
IK_DIR_IMPORT=/tmp/iktmp/import
IK_DIR_EXPORT=/tmp/iktmp/export
IK_DIR_HOSTS=/tmp/iktmp/ik_hosts
IK_DIR_BASIC_NOTIFY=/etc/basic/notify.d
IK_DIR_VRRP=/tmp/iktmp/vrrp

IK_DB_CONFIG=$IK_DIR_CONF/config.db
IK_DB_SYSLOG=$IK_DIR_LOG/syslog.db
IK_DB_COLLECTION=$IK_DIR_LOG/collection.db
IK_AC_PSK_DB=$IK_DIR_CONF/wpa_ppsk.db

Syslog()
{
	logger -t sys_event "$*"
}

Include()
{
	local file
	for file in ${@//,/ } ;do
		if [ ! "${___INCLUDE_ALREADY_LOAD_FILE___[$file]}" ];then
			___INCLUDE_ALREADY_LOAD_FILE___[$file]=1
			. $IK_DIR_INCLUDE/$file ""
		fi
	done
}

I18nload()
{
	local file
	for file in ${@//,/ } ;do
		if [ ! "${___I18N_ALREADY_LOAD_FILE___[$file]}" ];then
			if [ ! -f $IK_DIR_CACHE/i18n/$file.sh ];then
				json_decode_file_to_cache i18n_${file%%.*} $IK_DIR_I18N/$file $IK_DIR_CACHE/i18n/$file.sh
			fi

			___I18N_ALREADY_LOAD_FILE___[$file]=1
			. $IK_DIR_CACHE/i18n/$file.sh 2>/dev/null
		fi
	done
}

Show()
{
	local ____TYPE_SHOW____
	local ____SHOW_TOTAL_AND_DATA____
	local TYPE=${TYPE:-data}

	for ____TYPE_SHOW____ in ${TYPE//,/ } ;do
		if ! __show_$____TYPE_SHOW____ ;then
			if ! declare -F __show_$____TYPE_SHOW____ >/dev/null 2>&1 ;then
				echo "unknown TYPE ($____TYPE_SHOW____)" ;return 1
			fi
		fi
	done

	eval echo -n \"\$$1\"
}

json_output()
{
	if [ -n "$*" ];then
		local __json
		for param in $* ;do
			case "${param//*:}" in
			  bool) __json+="${__json:+,}\\\"${param//:*}\\\":\${${param//:*}:-false}" ;;
			  int) __json+="${__json:+,}\\\"${param//:*}\\\":\${${param//:*}:-0}" ;;
			  str) __json+="${__json:+,}\\\"${param//:*}\\\":\\\"\${${param//:*}//\\\"/\\\\\\\"}\\\"" ;;
			 json) __json+="${__json:+,}\\\"${param//:*}\\\":\${${param//:*}:-\{\}}" ;;
			 join) __json+="\${${param//:*}:+,\$${param//:*}}" ;;
			esac
		done
		eval echo -n \"\{$__json\}\"
	fi
}

json_append()
{
	if [ -n "$2" ];then
		local __json
		for param in ${@:2} ;do
			case "${param//*:}" in
			  int) __json+="${__json:+,}\\\"${param//:*}\\\":\${${param//:*}:-0}" ;;
			  str) __json+="${__json:+,}\\\"${param//:*}\\\":\\\"\${${param//:*}//\\\"/\\\\\\\"}\\\"" ;;
			 json) __json+="${__json:+,}\\\"${param//:*}\\\":\${${param//:*}:-\{\}}" ;;
			 join) __json+="\${${param//:*}:+,\$${param//:*}}" ;;
			esac
		done
		eval eval \$1="{\'\${$1:1:\${#$1}-2}\'\${$1:+,}\${__json}}"
	fi
}

auth_plugin() {

    local PUBLIC_KEY='
-----BEGIN PUBLIC KEY-----
MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAwnlZx4PHTLGIWFSJ7jvQ
X20LkRtRKZuw5MquSqkWOC0itGQX9Ed6VSPG7tx+ZKKY+uEJ2dqwbj4Py2zpyRO3
+fWylLB4IMPmIDYPH8f+JNsxEsxSw+G4tj/bqSzEckI6lfo15vGujUNHqzQtVC6a
GlAZPZNfjd8Yxn7THtWz+G2CYg5ncx20ZdSX9F8S/N9cnHe/8DrZLu3Svk4CwATX
2UjCut+bjij+W6SnwOtVWvvhTnVybV9uGecWnEyegXC6XVO9f7z6Gdsn0zkNHA0z
taED5c4gV21ZKPoxRy7mjgYeNHnkbCYHXuVRA/sahSiSGAaJ0DIAzPd4HFum9Ydb
lQIDAQAB
-----END PUBLIC KEY-----
'
    local TEMP_KEY=$(mktemp)
    local TEMP_ACTCODE=$(mktemp)
    local TEMP_SIGNATURE=$(mktemp)
    echo "$PUBLIC_KEY" > "$TEMP_KEY"

	ARCH=$(cat /etc/release | grep ARCH= | sed 's/ARCH=//g')

    if [ $ARCH = "x86" ]; then
      BOOTHDD=$(cat /etc/release | grep BOOTHDD= | sed 's/BOOTHDD=//g')
      EMBED_FACTORY_PART_OFFSET=0
      eep_mtd=/dev/${BOOTHDD}2
      activationCode=$(hexdump -v -s $((0x8C + $EMBED_FACTORY_PART_OFFSET)) -n 10 -e '1/1 "%02x"' $eep_mtd)
    else
      eep_mtd=/dev/$(cat /proc/mtd | grep "Factory" | cut -d ":" -f 1)
      EMBED_FACTORY_PART_OFFSET=$(cat /etc/release | grep EMBED_FACTORY_PART_OFFSET= | sed 's/EMBED_FACTORY_PART_OFFSET=//g')
      activationCode=$(hexdump -v -s $((0x8C + $EMBED_FACTORY_PART_OFFSET)) -n 10 -e '1/1 "%02x"' $eep_mtd)
    fi

    
    expire_hex=$(hexdump -v -s $((0x2008 + 256 + $EMBED_FACTORY_PART_OFFSET)) -n 8 -e '1/1 "%02x"' $eep_mtd)
    feature_hex=$(hexdump -v -s $((0x2008 + 256 + 8 + $EMBED_FACTORY_PART_OFFSET)) -n 4 -e '1/1 "%02x"' $eep_mtd)

    printf "%s" "$activationCode" > "$TEMP_ACTCODE"
    printf "%s" "$expire_hex" >> "$TEMP_ACTCODE"
    if [  "$feature_hex" != "00000000" ] && [  "$feature_hex" != "ffffffff" ]; then
        printf "%s" "$feature_hex" >> "$TEMP_ACTCODE"
    fi

    dd if=$eep_mtd bs=1 skip=$((0x2008 + $EMBED_FACTORY_PART_OFFSET)) count=256 of=$TEMP_SIGNATURE >/dev/null 2>&1

    openssl dgst -sha256 -verify "$TEMP_KEY" -signature "$TEMP_SIGNATURE" "$TEMP_ACTCODE" >/dev/null
    ret=$? 

    rm $TEMP_KEY $TEMP_ACTCODE $TEMP_SIGNATURE

    if [ $ret -ne 0 ]; then
        echo "系统未正常激活！"
        return 1
    fi

	[[ -z "$FEATURE_ID" || "$FEATURE_ID" = "0" ]] && return 0

	local config_hex=0x$(hexdump -v -s $((0x2008 + 256 + 8 + $EMBED_FACTORY_PART_OFFSET)) -n 4 -e '1/1 "%02x"' $eep_mtd)
	local config_dec=$((config_hex))

    if (( (config_dec & (1 << $FEATURE_ID)) != 0 )); then
        return 0
    else
        echo "该插件未获授权！"
        return 1
    fi
}

Include json.sh,fsyslog.sh,sqlite.sh,check_varl.sh

opensslmd5=$(md5sum $(which openssl) | cut -d ' ' -f 1)
ARCH=$(cat /etc/release | grep ARCH= | sed 's/ARCH=//g')

opensslstatus=0
[ $ARCH = "x86" -a "$opensslmd5" != "8dc48f57409edca7a781e6857382687b" ] && opensslstatus=1
[ $ARCH = "arm" -a "$opensslmd5" != "73b27bccb24fbf235e4cbe0fe80944b1" ] && opensslstatus=1
[ $ARCH = "mips" -a "$opensslmd5" != "2c7b4e5f15868e026c9227a7973b367b" ] && opensslstatus=1
if [ $opensslstatus -eq 1 ]; then
	echo "系统内核错误！"
	exit 1
fi

if [ "$ENABLE_FEATURE_CHECK" = "1" ]; then
	auth_plugin || exit 1
fi

Command $@
