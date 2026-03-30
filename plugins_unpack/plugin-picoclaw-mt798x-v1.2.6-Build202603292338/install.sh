#!/bin/bash
BASH_SOURCE=$0
INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_NAME="$(jq -r '.name' $INSTALL_DIR/html/metadata.json)"
chmod +x $INSTALL_DIR/script/*
. /etc/mnt/plugins/configs/config.sh

CHROOTDIR=$(chrootmgt get_chroot_dir)
CLAWBINDIR=$EXT_PLUGIN_INSTALL_DIR/$PLUGIN_NAME/bin
IK_SYSINFO_DIR=$CHROOTDIR$EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/workspace/iksysinfo

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

  for i in $(seq 1 5); do
		picoclawid1=$(pidof picoclaw)
    picoclawid2=$(pidof picoclaw-launcher)
		if [[ -n "$picoclawid1" || -n "$picoclawid2" ]]; then
			/usr/ikuai/function/plugin_$PLUGIN_NAME stop 2>/dev/null
			kill -9 $picoclawid1 2>/dev/null
      kill -9 $picoclawid2 2>/dev/null
			continue
		else
			break
		fi
	done

  for i in $(seq 1 5); do
    mountclean=0
    mount | grep $IK_SYSINFO_DIR/syslog.db && mountclean=1
    mount | grep $IK_SYSINFO_DIR/collection.db && mountclean=1
    if [ $mountclean -eq 1 ]; then
      umount $IK_SYSINFO_DIR/syslog.db 2>/dev/null
      umount $IK_SYSINFO_DIR/collection.db 2>/dev/null 
      continue
    else
			break
		fi
  done 

	# Common 安装项
	rm -rf /usr/ikuai/www/plugins/$PLUGIN_NAME
	ln -sf $INSTALL_DIR/html /usr/ikuai/www/plugins/$PLUGIN_NAME
	ln -sf $INSTALL_DIR/script/service.sh /usr/ikuai/function/plugin_$PLUGIN_NAME
	ln -sf ./install.sh $INSTALL_DIR/uninstall.sh

  # 首次安装或重新安装，则初始化配置文件
	if [ "$type" = "new" -o "$type" = "reinstall" ]; then
		debug "Picoclaw初始化配置文件"
		rm -rf $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME
		mkdir -p $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/
	fi

  # 启动虚拟环境
  chrootmgt mount_plugin "$PLUGIN_NAME"
  chrootmgt set_profile "export PICOCLAW_HOME=$EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME" "$PLUGIN_NAME"
  chrootmgt set_profile "export PICOCLAW_CONFIG=$EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/config.json" "$PLUGIN_NAME"
  chrootmgt set_profile "export PICOCLAW_AGENTS_DEFAULTS_RESTRICT_TO_WORKSPACE=true" "$PLUGIN_NAME"
  chrootmgt set_profile "export PICOCLAW_AGENTS_ALLOW_READ_OUTSIDE_WORKSPACE=false" "$PLUGIN_NAME"
  chrootmgt set_profile "export PICOCLAW_TOOLS_ALLOW_READ_PATHS=/proc," "$PLUGIN_NAME"

  # 将系统日志数据库和sqlite3命令注入虚拟环境
  chrootmgt install_bin "/usr/bin/sqlite3" >/dev/null 2>&1
  chrootmgt install_bin "/bin/dmesg" >/dev/null 2>&1
  mkdir -p $IK_SYSINFO_DIR && touch $IK_SYSINFO_DIR/syslog.db $IK_SYSINFO_DIR/collection.db
  mount --bind /etc/log/syslog.db $IK_SYSINFO_DIR/syslog.db
  mount --bind /etc/log/collection.db $IK_SYSINFO_DIR/collection.db

  # 初始化配置和技能
  if [ "$type" = "new" -o "$type" = "reinstall" ]; then
    # chrootmgt run "$CLAWBINDIR/picoclaw onboard"
    cp -rf  $INSTALL_DIR/bin/workspace $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/
    cp -f  $INSTALL_DIR/bin/config.json $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/
    cp -f  $INSTALL_DIR/bin/.security.yml $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/
    # jq '.channels.feishu.placeholder = {"enabled": true, "text": "等一下哦，小皮皮正在思考... 💭"} 
    #   | .tools.web.searxng = {"enabled": true,"base_url": "http://101.201.180.26:8509/","max_results": 5}' \
    #   $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/config.json > /tmp/picoclawconfig.json.tmp && 
    # mv /tmp/picoclawconfig.json.tmp $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/config.json
    chrootmgt run "$CLAWBINDIR/picoclaw skills remove tmux"
    chrootmgt run "$CLAWBINDIR/picoclaw skills remove github"
    chrootmgt run "$CLAWBINDIR/picoclaw skills remove hardware"
    chrootmgt run "$CLAWBINDIR/picoclaw skills remove summarize"
  fi
  
	# 自动启动插件
	if [ -f "$EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME/autostart" ]; then
		/usr/ikuai/function/plugin_$PLUGIN_NAME start
	fi
	debug "插件 $PLUGIN_NAME 安装完成"
	touch /tmp/iktmp/plugins/${PLUGIN_NAME}_installed
}

__uninstall()
{
	/usr/ikuai/function/plugin_$PLUGIN_NAME stop
  for i in $(seq 1 3); do
    killall picoclaw 2>/dev/null
    killall picoclaw-launcher 2>/dev/null
    umount $IK_SYSINFO_DIR/syslog.db 2>/dev/null
    umount $IK_SYSINFO_DIR/collection.db 2>/dev/null
  done 

  chrootmgt umount_plugin "$PLUGIN_NAME"
	chrootmgt clean_profile "$PLUGIN_NAME"

  rm -f /tmp/iktmp/plugins/${PLUGIN_NAME}_installed
 
	# 通用卸载项
	rm -rf $INSTALL_DIR
	rm -rf /usr/ikuai/www/plugins/$PLUGIN_NAME
	rm -rf $EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME
	rm -f $EXT_PLUGIN_IPK_DIR/$PLUGIN_NAME.ipk
	rm -f $EXT_PLUGIN_LOG_DIR/$PLUGIN_NAME.log
	rm -f /usr/ikuai/function/plugin_$PLUGIN_NAME
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
