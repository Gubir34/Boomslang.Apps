#!/bin/sh
. /useremain/rinkhals/.current/tools.sh

APP_ROOT=$(dirname "$(realpath "$0")")
APP=print-notifications
PID_FILE=/tmp/rinkhals/$APP.pid
LOG_FILE=$RINKHALS_LOGS/app-$APP.log

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
    mkdir -p /tmp/rinkhals
    chmod +x $APP_ROOT/notifier.sh
    nohup sh $APP_ROOT/notifier.sh >> $LOG_FILE 2>&1 &
    echo $! > $PID_FILE
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
