#!/bin/sh
. /useremain/rinkhals/.current/tools.sh

APP_ROOT=$(dirname "$(realpath "$0")")
APP=quick-links
MARKER=/tmp/rinkhals/$APP.started
USER_APPS=/useremain/home/rinkhals/apps

printer_ip() {
    ip=$(ip route get 1.1.1.1 2> /dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
    [ -z "$ip" ] && ip=$(ifconfig 2> /dev/null | sed -n 's/.*inet addr:\([0-9.]*\).*/\1/p' | grep -v '^127\.' | head -n 1)
    echo "${ip:-printer-ip}"
}

# The port an app is configured with, or its default
app_port() {
    v=$(jq -r '.port // empty' $USER_APPS/$1.config 2> /dev/null)
    case "$v" in ''|*[!0-9]*) v=$2 ;; esac
    echo $v
}

link() {
    # link <property> <app folder or empty> <port> <name>
    if [ -n "$2" ] && [ ! -d "$USER_APPS/$2" ]; then
        set_temporary_app_property $APP $1 "Install $4 from the App Store first"
    else
        set_temporary_app_property $APP $1 "http://$IP:$3"
    fi
}

status() {
    if [ -f $MARKER ]; then
        report_status $APP_STATUS_STARTED
    else
        report_status $APP_STATUS_STOPPED
    fi
}

start() {
    mkdir -p /tmp/rinkhals
    IP=$(printer_ip)
    link mainsail "" 4409 Mainsail
    link fluidd "" 4408 Fluidd
    link portal "" 8090 "the web portal"
    link timelapse timelapse-viewer "$(app_port timelapse-viewer 8091)" "Timelapse viewer"
    link monitor system-monitor "$(app_port system-monitor 8092)" "System monitor"
    link game boomslang-hop "$(app_port boomslang-hop 8093)" "Boomslang Hop"
    touch $MARKER
}

stop() {
    rm -f $MARKER
}

case "$1" in
    status) status ;;
    start) start ;;
    stop) stop ;;
    version) jq -r .version $APP_ROOT/app.json ;;
    *) echo "Usage: $0 {status|start|stop}" >&2; exit 1 ;;
esac
