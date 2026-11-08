#!/bin/sh
. /useremain/rinkhals/.current/tools.sh

APP_ROOT=$(dirname "$(realpath "$0")")
APP=timelapse-viewer
PID_FILE=/tmp/rinkhals/$APP.pid
LOG_FILE=$RINKHALS_LOGS/app-$APP.log
USER_CONFIG=/useremain/home/rinkhals/apps/$APP.config
VIDEO_DIR=/useremain/app/gk/Time-lapse-Video

setting() {
    v=$(jq -r --arg k "$1" '.[$k] // empty' $USER_CONFIG 2> /dev/null)
    [ -z "$v" ] && v=$(jq -r --arg k "$1" '.properties[$k].default // empty' $APP_ROOT/app.json)
    echo "$v"
}

printer_ip() {
    ip=$(ip route get 1.1.1.1 2> /dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
    [ -z "$ip" ] && ip=$(ifconfig 2> /dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | grep -v '^127\.' | head -n 1)
    echo "${ip:-printer-ip}"
}

status() {
    PID=$(cat $PID_FILE 2> /dev/null)
    if [ -n "$PID" ] && kill -0 $PID 2> /dev/null; then
        report_status $APP_STATUS_STARTED "$PID" $LOG_FILE
    else
        report_status $APP_STATUS_STOPPED "" $LOG_FILE
    fi
}

start() {
    stop
    mkdir -p /tmp/rinkhals /useremain/tmp $VIDEO_DIR
    PORT=$(setting port); case "$PORT" in ''|*[!0-9]*) PORT=8091 ;; esac

    printf 'VIDEO_DIR=%s\nUSER_CONFIG=%s\n' "$VIDEO_DIR" "$USER_CONFIG" > $APP_ROOT/runtime.env
    sed -e "s#\./#$APP_ROOT/#g" -e "s#__PORT__#$PORT#g" -e "s#__VIDEO_DIR__#$VIDEO_DIR#g" \
        $APP_ROOT/lighttpd.conf > /tmp/rinkhals/$APP.lighttpd.conf

    lighttpd -D -f /tmp/rinkhals/$APP.lighttpd.conf >> $LOG_FILE 2>&1 &
    echo $! > $PID_FILE
    set_temporary_app_property $APP open_link "http://$(printer_ip):$PORT"
}

stop() {
    PID=$(cat $PID_FILE 2> /dev/null)
    [ -n "$PID" ] && kill $PID 2> /dev/null
    rm -f $PID_FILE
}

case "$1" in
    status) status ;;
    start) start ;;
    stop) stop ;;
    version) jq -r .version $APP_ROOT/app.json ;;
    *) echo "Usage: $0 {status|start|stop}" >&2; exit 1 ;;
esac
