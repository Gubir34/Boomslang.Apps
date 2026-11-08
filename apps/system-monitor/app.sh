#!/bin/sh
. /useremain/rinkhals/.current/tools.sh

APP_ROOT=$(dirname "$(realpath "$0")")
APP=system-monitor
PID_FILE=/tmp/rinkhals/$APP.pid
LOG_FILE=$RINKHALS_LOGS/app-$APP.log
USER_CONFIG=/useremain/home/rinkhals/apps/$APP.config
DATA_DIR=/tmp/system-monitor
COLLECTOR_PID_FILE=/tmp/rinkhals/$APP-collector.pid

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
    CPID=$(cat $COLLECTOR_PID_FILE 2> /dev/null)
    if [ -n "$PID" ] && kill -0 $PID 2> /dev/null; then
        report_status $APP_STATUS_STARTED "$PID $CPID" $LOG_FILE
    else
        report_status $APP_STATUS_STOPPED "" $LOG_FILE
    fi
}

start() {
    stop
    mkdir -p /tmp/rinkhals /useremain/tmp $DATA_DIR
    PORT=$(setting port); case "$PORT" in ''|*[!0-9]*) PORT=8092 ;; esac

    DATA_DIR=$DATA_DIR nohup sh $APP_ROOT/collector.sh >> $LOG_FILE 2>&1 &
    echo $! > $COLLECTOR_PID_FILE

    sed -e "s#\./#$APP_ROOT/#g" -e "s#__PORT__#$PORT#g" -e "s#__DATA_DIR__#$DATA_DIR#g" \
        $APP_ROOT/lighttpd.conf > /tmp/rinkhals/$APP.lighttpd.conf
    lighttpd -D -f /tmp/rinkhals/$APP.lighttpd.conf >> $LOG_FILE 2>&1 &
    echo $! > $PID_FILE
    set_temporary_app_property $APP open_link "http://$(printer_ip):$PORT"
}

stop() {
    for f in $PID_FILE $COLLECTOR_PID_FILE; do
        PID=$(cat $f 2> /dev/null)
        [ -n "$PID" ] && kill $PID 2> /dev/null
        rm -f $f
    done
}

case "$1" in
    status) status ;;
    start) start ;;
    stop) stop ;;
    version) jq -r .version $APP_ROOT/app.json ;;
    *) echo "Usage: $0 {status|start|stop}" >&2; exit 1 ;;
esac
