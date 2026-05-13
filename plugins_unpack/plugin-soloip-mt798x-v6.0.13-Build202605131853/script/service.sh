#!/bin/bash
FEATURE_ID=0
ENABLE_FEATURE_CHECK=1
# iKuai Plugin Service Script for SoloIP
# Link this to /usr/ikuai/function/plugin_soloip

. /etc/mnt/plugins/configs/config.sh

PLUGIN_NAME="soloip"
BIN_DIR="$EXT_PLUGIN_INSTALL_DIR/$PLUGIN_NAME/bin"
CONF_DIR="$EXT_PLUGIN_CONFIG_DIR/$PLUGIN_NAME"
LOG_FILE="$EXT_PLUGIN_LOG_DIR/$PLUGIN_NAME.log"
WATCHDOG_PID_FILE="/tmp/soloip_watchdog.pid"

debug() {
    local debuglog=$( [ -s /tmp/debug_on ] && cat /tmp/debug_on || echo -n /tmp/debug.log )
    if [ -f /tmp/debug_on ]; then
        local TIME_STAMP=$(date +"%Y%m%d %H:%M:%S")
        echo "[$TIME_STAMP]: PL_SRV> $1" >>$debuglog
    fi
}

log_message() {
    local TIME_STAMP=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$TIME_STAMP] [Service] $1" >> "$LOG_FILE"
}

is_running() {
    pidof soloip >/dev/null 2>&1
    return $?
}

start() {
    if is_running; then
        echo "SoloIP is already running."
        return 0
    fi

    log_message "Starting SoloIP daemon..."
    export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
    export SOLOIP_CONFIG_PATH="$CONF_DIR"

    # 清理残留 CrashCore 孤儿进程（Go 进程已退出但 CrashCore 因 Setsid 存活）
    killall CrashCore 2>/dev/null
    sleep 1
    
    $BIN_DIR/soloip >> "$LOG_FILE" 2>&1 &
    
    # Wait a bit and check
    sleep 2
    if is_running; then
        echo "SoloIP started successfully."
        
        # ================================================================
        # 动态注入 OpenResty 反向代理 (解决 Rtty 和 CORS 问题)
        # ================================================================
        local NGINX_CONF="/usr/openresty/conf/webman.conf"
        if [ -f "$NGINX_CONF" ] && ! grep -q "location /soloip/" "$NGINX_CONF" 2>/dev/null; then
            debug "注入 OpenResty 反向代理配置"
            cat << 'EOF' >> "$NGINX_CONF"

# --- SoloIP Proxy Start ---
location /soloip/ {
	proxy_pass http://127.0.0.1:28081/soloip/;
	proxy_set_header Host $host;
	proxy_set_header X-Real-IP $remote_addr;
	proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
	proxy_http_version 1.1;
	proxy_set_header Upgrade $http_upgrade;
	proxy_set_header Connection "upgrade";
}
# --- SoloIP Proxy End ---
EOF
            # 重载 OpenResty 使配置生效
            openresty -s reload 2>/dev/null || true
        fi

        start_watchdog
        return 0
    else
        echo "Failed to start SoloIP."
        return 1
    fi
}

stop() {
    log_message "Stopping SoloIP service..."
    stop_watchdog
    
    local daemon_pid=$(pidof soloip 2>/dev/null)
    if [ -n "$daemon_pid" ]; then
        kill $daemon_pid 2>/dev/null
        for i in 1 2 3 4 5; do
            sleep 1
            kill -0 $daemon_pid 2>/dev/null || break
        done
        kill -0 $daemon_pid 2>/dev/null && kill -9 $daemon_pid 2>/dev/null
    fi
    
    # Also cleanup associated cores if any
    killall CrashCore 2>/dev/null
    
    echo "SoloIP stopped."
    return 0
}

status() {
    if is_running; then
        local pid=$(pidof soloip)
        echo "SoloIP is running (pid $pid)."
        if [ -f "$WATCHDOG_PID_FILE" ] && kill -0 $(cat "$WATCHDOG_PID_FILE") 2>/dev/null; then
            echo "Watchdog is active (pid $(cat $WATCHDOG_PID_FILE))."
        else
            echo "Watchdog is NOT active."
        fi
        return 0
    else
        echo "SoloIP is stopped."
        return 3
    fi
}

keepalive() {
    log_message "Watchdog started (pid $$)"
    while true; do
        # Only restart if autostart is enabled (the daemon handles its own autostart setting in DB)
        # However, as a simple watchdog, we just check if it's supposed to be running.
        # We can check a flag file or just assume if watchdog is running, daemon should be too.
        if ! is_running; then
            log_message "Watchdog: SoloIP daemon is down! Restarting..."
            # 清理残留 CrashCore 孤儿进程
            killall CrashCore 2>/dev/null
            sleep 1
            export SOLOIP_CONFIG_PATH="$CONF_DIR"
            $BIN_DIR/soloip >> "$LOG_FILE" 2>&1 &
            log_message "Watchdog: Restarted SoloIP (new pid $!)"
        fi
        sleep 60
    done
}

start_watchdog() {
    stop_watchdog
    keepalive >> "$LOG_FILE" 2>&1 &
    echo $! > "$WATCHDOG_PID_FILE"
    log_message "Watchdog launched in background."
}

stop_watchdog() {
    if [ -f "$WATCHDOG_PID_FILE" ]; then
        local wpid=$(cat "$WATCHDOG_PID_FILE")
        if [ -n "$wpid" ]; then
            kill $wpid 2>/dev/null
        fi
        rm -f "$WATCHDOG_PID_FILE"
        log_message "Watchdog stopped."
    fi
}

case "$1" in
    start)
        start
        ;;
    stop)
        stop
        ;;
    restart)
        stop
        start
        ;;
    status)
        status
        ;;
    keepalive)
        # This is for internal use or manual testing
        keepalive
        ;;
    *)
        exit 1
        ;;
esac
