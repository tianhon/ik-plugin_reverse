#!/bin/bash
BASH_SOURCE=$0
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_NAME="$(jq -r '.name' $INSTALL_DIR/html/metadata.json)"
. /etc/mnt/plugins/configs/config.sh
BIN_DIR="$EXT_PLUGIN_INSTALL_DIR/$PLUGIN_NAME/bin"
CONF_DIR="$EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME"
DHCP_ACL_LOCK="/tmp/soloip_laniso_dhcp_acl.lock"
DHCP_ACL_FUNCTION="/usr/ikuai/function/dhcp_acl_mac"

debug() {
	debuglog=$( [ -s /tmp/debug_on ] && cat /tmp/debug_on || echo -n /tmp/debug.log )
    if [ "$1" = "clear" ]; then
        rm -f $debuglog && return
    fi

    if [ -f /tmp/debug_on ]; then
        TIME_STAMP=$(date +"%Y%m%d %H:%M:%S")
        echo "[$TIME_STAMP]: PL> $1" >>$debuglog
    fi
}

release_lan_isolation_dhcp_acl()
{
	[ -f "$DHCP_ACL_LOCK" ] || return 0

	if [ -x "$DHCP_ACL_FUNCTION" ]; then
		SOLOIP_DHCP_ACL_OWNER=soloip "$DHCP_ACL_FUNCTION" soloip_laniso_clear >/dev/null 2>&1 || true
	fi
	rm -f "$DHCP_ACL_LOCK"
}

cleanup_lan_isolation_runtime()
{
	export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

	if [ -x "$BIN_DIR/soloip" ]; then
		SOLOIP_CONFIG_PATH="$CONF_DIR" GODEBUG=asyncpreemptoff=1 \
			"$BIN_DIR/soloip" --cleanup-lan-isolation-runtime >/dev/null 2>&1 || true
	fi

	release_lan_isolation_dhcp_acl
}

install()
{
	# 安装类型如下：
	# 1、new:新安装; 
	# 2、upgrade:保留配置更新; 
	# 3、reinstall:不保留配置更新; 
	# 4、boot:开机启动
	type=$1 
	debug "开始安装$PLUGIN_NAME ,安装类型为：$type"
	rm -f /tmp/iktmp/plugins/${PLUGIN_NAME}_installed

	# ================================================================
	# 1. 停止旧版进程（通过服务脚本或强杀兜底）
	# ================================================================
	debug "检查并停止旧版进程"
	if [ -L "/usr/ikuai/function/plugin_$PLUGIN_NAME" ]; then
		/usr/ikuai/function/plugin_$PLUGIN_NAME stop >/dev/null 2>&1
	fi
	
	# 兜底强杀
	local daemon_pid=$(pidof soloip 2>/dev/null)
	[ -n "$daemon_pid" ] && kill -9 $daemon_pid 2>/dev/null
	killall soloip 2>/dev/null
	killall CrashCore 2>/dev/null
	sleep 1

	# ================================================================
	# 2. 通用安装项
	# ================================================================
	rm -rf /usr/ikuai/www/plugins/$PLUGIN_NAME
	ln -sf $INSTALL_DIR/html /usr/ikuai/www/plugins/$PLUGIN_NAME
	
	# 链接服务脚本
	chmod +x $INSTALL_DIR/script/service.sh
	ln -sf $INSTALL_DIR/script/service.sh /usr/ikuai/function/plugin_$PLUGIN_NAME
	
	ln -sf ./install.sh $INSTALL_DIR/uninstall.sh

	# ================================================================
	# 3. 数据目录初始化
	# ================================================================
	# 首次安装或重新安装，则初始化数据目录（清空旧数据）
	if [ "$type" = "new" -o "$type" = "reinstall" ]; then
		debug "初始化数据目录"
		rm -rf $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME
	fi

	# 确保数据目录存在
	mkdir -p $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME
  cp -f $EXT_PLUGIN_INSTALL_DIR/$PLUGIN_NAME/html/metadata.json $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/metadata.json

	# ================================================================
	# 4. 设置可执行文件权限
	# ================================================================
	debug "设置二进制文件权限"
	chmod +x $BIN_DIR/soloip 2>/dev/null

	# ================================================================
	# 5. 启动服务（通过服务脚本，带 Watchdog）
	# ================================================================
	debug "启动 SoloIP 服务"
	if ! /usr/ikuai/function/plugin_$PLUGIN_NAME start; then
		debug "启动 SoloIP 服务失败"
		return 1
	fi

	debug "插件 $PLUGIN_NAME 安装完成"
	touch /tmp/iktmp/plugins/${PLUGIN_NAME}_installed
}

__uninstall()
{
	# 停止服务（包含停止 Watchdog）
	if [ -L "/usr/ikuai/function/plugin_$PLUGIN_NAME" ]; then
		/usr/ikuai/function/plugin_$PLUGIN_NAME stop >/dev/null 2>&1
	fi
	cleanup_lan_isolation_runtime
	killall soloip 2>/dev/null
	killall CrashCore 2>/dev/null

	rm -f /tmp/iktmp/plugins/${PLUGIN_NAME}_installed

	# 通用卸载项
	rm -rf $INSTALL_DIR
	rm -rf /usr/ikuai/www/plugins/$PLUGIN_NAME
	rm -rf $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME
	rm -f $EXT_PLUGIN_IPK_DIR/$PLUGIN_NAME.ipk
	rm -f $EXT_PLUGIN_LOG_DIR/$PLUGIN_NAME.log
	rm -f /usr/ikuai/function/plugin_$PLUGIN_NAME

	# 清理 OpenResty 反向代理
	local NGINX_CONF="/usr/openresty/conf/webman.conf"
	if [ -f "$NGINX_CONF" ] && grep -q "# --- SoloIP Proxy Start ---" "$NGINX_CONF" 2>/dev/null; then
		sed -i '/# --- SoloIP Proxy Start ---/,/# --- SoloIP Proxy End ---/d' "$NGINX_CONF"
		openresty -s reload 2>/dev/null || true
	fi
}

uninstall()
{
	__uninstall >/dev/null 2>&1
}

procname=$(basename $BASH_SOURCE)
if [ "$procname" = "install.sh" ];then
        install ${1-boot}
elif [ "$procname" = "uninstall.sh" ];then
        uninstall
fi
