#!/bin/sh
# Automatic backup for Boomslang. BusyBox ash compatible.
# Paths can be overridden for testing:
#   USER_CONFIG, APP_JSON, STATE_FILE, MOONRAKER_URL, USB_DIR, USB_MOUNTS,
#   BACKUP_ROOT (prefix for the backed up paths), START_DELAY, CHECK_INTERVAL

APP=auto-backup
APP_ROOT=$(dirname "$(realpath "$0")")

USER_CONFIG=${USER_CONFIG:-/useremain/home/rinkhals/apps/$APP.config}
APP_JSON=${APP_JSON:-$APP_ROOT/app.json}
STATE_FILE=${STATE_FILE:-/useremain/home/rinkhals/apps/$APP.last}
MOONRAKER_URL=${MOONRAKER_URL:-http://127.0.0.1:7125}
USB_DIR=${USB_DIR:-/mnt/udisk}
USB_MOUNTS=${USB_MOUNTS:-/proc/mounts}
BACKUP_ROOT=${BACKUP_ROOT:-}
START_DELAY=${START_DELAY:-300}
CHECK_INTERVAL=${CHECK_INTERVAL:-60}

# What goes into a backup, relative to / (missing paths are skipped)
CONFIG_PATHS="userdata/app/gk/printer_data/config useremain/home/rinkhals/printer_data/config"
DATABASE_PATH="userdata/app/gk/printer_data/database"
APP_SETTINGS_DIR="useremain/home/rinkhals/apps"

say() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

LAST_REPORT=
report() {
    [ "$1" = "$LAST_REPORT" ] && return
    LAST_REPORT=$1
    say "status: $1"
    if command -v set_temporary_app_property > /dev/null 2>&1; then
        set_temporary_app_property $APP status "$(echo "$1" | tr -d '"\\')" 2> /dev/null
    fi
}

CONFIG_STAMP=
load_config() {
    stamp=$(md5sum "$USER_CONFIG" 2> /dev/null)
    [ "$stamp" = "$CONFIG_STAMP" ] && [ -n "$CFG_destination" ] && return 1
    CONFIG_STAMP=$stamp
    user=$USER_CONFIG
    [ -s "$user" ] || user=/dev/null
    eval "$(jq -r -n --slurpfile a "$APP_JSON" --rawfile u "$user" '
        ($a[0].properties | map_values(.default // "")) +
        (($u | if . == "" then {} else fromjson end) // {})
        | to_entries[]
        | select(.key | test("^[a-z_]+$"))
        | "CFG_\(.key)=\(.value | tostring | @sh)"')"
    return 0
}

is_true() { case "$1" in True|true|1|yes) return 0 ;; esac; return 1; }
number() { case "$1" in ''|*[!0-9]*) echo "$2" ;; *) echo "$1" ;; esac; }

printing() {
    state=$(curl -s -m 5 "$MOONRAKER_URL/printer/objects/query?print_stats" | jq -r '.result.status.print_stats.state // empty' 2> /dev/null)
    [ "$state" = "printing" ] || [ "$state" = "paused" ]
}

destination() {
    if [ "$CFG_destination" = "folder" ]; then
        echo "${CFG_folder:-/useremain/boomslang-backups}"
    elif grep -q " $USB_DIR " "$USB_MOUNTS" 2> /dev/null; then
        echo "$USB_DIR/boomslang-backups"
    fi
}

backup() {
    dir=$(destination)
    if [ -z "$dir" ]; then
        report "Waiting for a USB drive (none plugged in)"
        return 1
    fi
    if ! mkdir -p "$dir" 2> /dev/null; then
        report "Cannot write to $dir"
        return 1
    fi

    cd "${BACKUP_ROOT:-/}" || return 1
    paths=
    for p in $CONFIG_PATHS; do [ -e "$p" ] && paths="$paths $p"; done
    for f in "$APP_SETTINGS_DIR"/*.config "$APP_SETTINGS_DIR"/*.enabled "$APP_SETTINGS_DIR"/*.disabled; do
        [ -e "$f" ] && paths="$paths $f"
    done
    is_true "$CFG_include_database" && [ -e "$DATABASE_PATH" ] && paths="$paths $DATABASE_PATH"
    if [ -z "$paths" ]; then
        report "Nothing to back up"
        return 1
    fi

    name=boomslang-backup-$(date +%Y%m%d-%H%M%S).tar.gz
    # shellcheck disable=SC2086
    if ! tar -czf "$dir/.$name.part" $paths 2> /tmp/$APP.err; then
        rm -f "$dir/.$name.part"
        report "Backup failed: $(head -c 120 /tmp/$APP.err)"
        return 1
    fi
    mv -f "$dir/.$name.part" "$dir/$name"
    sync

    keep=$(number "$CFG_keep" 10)
    [ "$keep" -lt 1 ] && keep=1
    ls -1 "$dir"/boomslang-backup-*.tar.gz 2> /dev/null | sort -r | tail -n +$((keep + 1)) | while read -r old; do
        rm -f "$old"
    done

    size=$(du -k "$dir/$name" | cut -f1)
    count=$(ls -1 "$dir"/boomslang-backup-*.tar.gz 2> /dev/null | wc -l)
    date +%s > "$STATE_FILE"
    report "$name ($size KB) in $dir, $count kept"
    return 0
}

load_config
report "Scheduled every $(number "$CFG_interval_hours" 24) h to $CFG_destination"

started=$(date +%s)
first=1
while true; do
    load_config && say "settings reloaded"
    now=$(date +%s)
    last=$(cat "$STATE_FILE" 2> /dev/null)
    last=$(number "$last" 0)
    # The clock starts at 1970 until it is synced: never wait forever on a
    # timestamp from the future
    [ "$last" -gt "$now" ] && last=0
    interval=$(( $(number "$CFG_interval_hours" 24) * 3600 ))
    [ "$interval" -lt 3600 ] && interval=3600

    due=
    [ $((now - last)) -ge "$interval" ] && due=1
    if [ -n "$first" ] && is_true "$CFG_backup_on_start" && [ $((now - started)) -ge "$START_DELAY" ]; then
        due=1
    fi

    if [ -n "$due" ]; then
        if printing; then
            say "printing, backup postponed"
        else
            backup
            first=
        fi
    fi
    [ -n "$first" ] && ! is_true "$CFG_backup_on_start" && first=
    sleep "$CHECK_INTERVAL"
done
