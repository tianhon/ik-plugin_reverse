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
FULL_STOP_MARKER="/tmp/soloip_full_stop"
PENDING_EVENT_DIR="$CONF_DIR/pending_event_reports"

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

soloip_godebug() {
    local value="${GODEBUG:-}" result="" part old_ifs
    if [ -z "$value" ]; then
        echo -n "asyncpreemptoff=1"
        return 0
    fi

    old_ifs="$IFS"
    IFS=","
    for part in $value; do
        case "$part" in
            ""|asyncpreemptoff|asyncpreemptoff=*)
                continue
                ;;
        esac
        if [ -z "$result" ]; then
            result="$part"
        else
            result="$result,$part"
        fi
    done
    IFS="$old_ifs"

    if [ -z "$result" ]; then
        echo -n "asyncpreemptoff=1"
    else
        echo -n "$result,asyncpreemptoff=1"
    fi
}

prune_pending_events() {
    [ -d "$PENDING_EVENT_DIR" ] || return 0
    local overflow
    overflow=$(ls -1t "$PENDING_EVENT_DIR"/*.json 2>/dev/null | tail -n +21)
    [ -n "$overflow" ] && echo "$overflow" | xargs rm -f 2>/dev/null
}

sync_persistent_killswitch() {
    log_message "Synchronizing persistent Kill-Switch..."
    GODEBUG="$(soloip_godebug)" "$BIN_DIR/soloip" --sync-persistent-killswitch >> "$LOG_FILE" 2>&1
}

cleanup_proxy_runtime() {
    [ -x "$BIN_DIR/soloip" ] || return 0

    log_message "Cleaning SoloIP proxy runtime..."
    SOLOIP_CONFIG_PATH="$CONF_DIR" GODEBUG="$(soloip_godebug)" \
        "$BIN_DIR/soloip" --cleanup-proxy-runtime >> "$LOG_FILE" 2>&1 || true
}

write_watchdog_event_marker() {
    mkdir -p "$PENDING_EVENT_DIR" 2>/dev/null || return 0
    prune_pending_events

    local now crash_exists marker
    now=$(date +%s)
    crash_exists=false
    [ -s /tmp/soloip_crash.log ] && crash_exists=true
    marker="$PENDING_EVENT_DIR/${now}-watchdog_restart.json"

    cat > "$marker" <<EOF
{
  "eventType": "watchdog_restart",
  "reporter": "shell_watchdog",
  "severity": "error",
  "detectedAt": $now,
  "watchdogPid": $$,
  "reason": "soloip process disappeared",
  "crashLogExists": $crash_exists
}
EOF
}

is_running() {
    pidof soloip >/dev/null 2>&1
    return $?
}

terminate_daemon() {
    local wait_seconds="${1:-5}"
    local daemon_pid
    daemon_pid=$(pidof soloip 2>/dev/null)
    if [ -z "$daemon_pid" ]; then
        return 0
    fi

    kill $daemon_pid 2>/dev/null
    local i=0
    while [ "$i" -lt "$wait_seconds" ]; do
        sleep 1
        pidof soloip >/dev/null 2>&1 || return 0
        i=$((i + 1))
    done
    daemon_pid=$(pidof soloip 2>/dev/null)
    [ -n "$daemon_pid" ] && kill -9 $daemon_pid 2>/dev/null
}

start() {
    rm -f "$FULL_STOP_MARKER"

    if is_running; then
        echo "SoloIP is already running."
        return 0
    fi

    log_message "Starting SoloIP daemon..."
    export PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
    export SOLOIP_CONFIG_PATH="$CONF_DIR"

    if ! sync_persistent_killswitch; then
        echo "Failed to synchronize SoloIP Kill-Switch."
        return 1
    fi

    # 不在 shell 启动阶段清理 CrashCore。
    # 如果 Go 守护进程崩溃但 CrashCore 仍在正常转发，新 Go 进程会优先通过本机 API 接管，
    # 避免无谓重启内核导致终端连接断开。

    GODEBUG="$(soloip_godebug)" $BIN_DIR/soloip >> "$LOG_FILE" 2>&1 &

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
    echo "$(date +%s)" > "$FULL_STOP_MARKER"

    terminate_daemon 12
    rm -f "$FULL_STOP_MARKER"
    cleanup_proxy_runtime
    
    # Also cleanup associated cores if any
    killall CrashCore 2>/dev/null
    
    echo "SoloIP stopped."
    return 0
}

stop_manager() {
    log_message "Stopping SoloIP manager only..."
    stop_watchdog
    rm -f "$FULL_STOP_MARKER"

    terminate_daemon 5

    echo "SoloIP manager stopped. CrashCore preserved."
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
            write_watchdog_event_marker
            # 只恢复 Go 管理进程，不直接重启 CrashCore。
            # CrashCore 是否健康由 Go 进程通过 /version 探测并自动接管或延迟重建。
            export SOLOIP_CONFIG_PATH="$CONF_DIR"
            rm -f "$FULL_STOP_MARKER"
            GODEBUG="$(soloip_godebug)" $BIN_DIR/soloip >> "$LOG_FILE" 2>&1 &
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
    stop-manager)
        stop_manager
        ;;
    restart-manager)
        stop_manager
        sleep 1
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
