#!/bin/sh
# Print notifications for Boomslang: watches the print state in Moonraker and
# sends a message on start, pause/resume, finish, error, cancel and progress
# steps. BusyBox ash compatible; needs curl and jq (both ship with Boomslang).
#
# Paths can be overridden for testing:
#   MOONRAKER_URL, USER_CONFIG, APP_JSON, POLL_INTERVAL, CA_FILE

APP=print-notifications
APP_ROOT=$(dirname "$(realpath "$0")")

MOONRAKER_URL=${MOONRAKER_URL:-http://127.0.0.1:7125}
USER_CONFIG=${USER_CONFIG:-/useremain/home/rinkhals/apps/$APP.config}
APP_JSON=${APP_JSON:-$APP_ROOT/app.json}
POLL_INTERVAL=${POLL_INTERVAL:-10}

if [ -z "$CA_FILE" ]; then
    for f in "$RINKHALS_ROOT/usr/lib/python3.11/site-packages/certifi/cacert.pem" /etc/ssl/certs/ca-certificates.crt; do
        [ -f "$f" ] && CA_FILE=$f && break
    done
fi
CURL="curl -s -m 15 --retry 2"
[ -n "$CA_FILE" ] && CURL="$CURL --cacert $CA_FILE"

say() { echo "[$(date '+%H:%M:%S')] $*"; }

# Show a line in the app's settings ("Status"); tools.sh is optional so the
# script can run on its own for testing
report() {
    say "status: $1"
    if command -v set_temporary_app_property > /dev/null 2>&1; then
        set_temporary_app_property $APP status "$(echo "$1" | tr -d '"\\')" 2> /dev/null
    fi
}

# Settings: the user's value, else the app.json default
CONFIG_STAMP=
load_config() {
    stamp=$(md5sum "$USER_CONFIG" 2> /dev/null)
    [ "$stamp" = "$CONFIG_STAMP" ] && [ -n "$CFG_service" ] && return 1
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

human_time() {
    s=${1:-0}; h=$((s / 3600)); m=$((s % 3600 / 60))
    if [ $h -gt 0 ]; then echo "${h}h ${m}m"; else echo "${m}m $((s % 60))s"; fi
}

# send <event> <title> <message>
send() {
    event=$1; title="$CFG_printer_name: $2"; message=$3
    case "$CFG_service" in
        ntfy)
            [ -z "$CFG_ntfy_topic" ] && { report "Set an ntfy topic to get notifications"; return 1; }
            case "$event" in
                complete) tags=white_check_mark; prio=default ;;
                error|cancelled) tags=warning; prio=high ;;
                paused) tags=pause_button; prio=default ;;
                started|resumed) tags=arrow_forward; prio=default ;;
                *) tags=snake; prio=low ;;
            esac
            $CURL -H "Title: $title" -H "Tags: $tags" -H "Priority: $prio" \
                --data-binary "$message" "${CFG_ntfy_server%/}/$CFG_ntfy_topic" > /dev/null
            ;;
        telegram)
            [ -z "$CFG_telegram_bot_token" ] || [ -z "$CFG_telegram_chat_id" ] && { report "Set the Telegram bot token and chat ID"; return 1; }
            $CURL -X POST "https://api.telegram.org/bot$CFG_telegram_bot_token/sendMessage" \
                --data-urlencode "chat_id=$CFG_telegram_chat_id" \
                --data-urlencode "text=$title
$message" > /dev/null
            ;;
        discord)
            [ -z "$CFG_discord_webhook_url" ] && { report "Set a Discord webhook URL"; return 1; }
            jq -n --arg t "$title" --arg m "$message" '{username: "Boomslang", content: "**\($t)**\n\($m)"}' |
                $CURL -H "Content-Type: application/json" --data-binary @- "$CFG_discord_webhook_url" > /dev/null
            ;;
        webhook)
            [ -z "$CFG_webhook_url" ] && { report "Set a webhook URL"; return 1; }
            jq -n --arg e "$event" --arg t "$title" --arg m "$message" --arg p "$CFG_printer_name" \
                  --arg f "$file" --arg s "$state" --argjson pr "${progress:-0}" \
                '{event: $e, title: $t, message: $m, printer: $p, file: $f, state: $s, progress: $pr}' |
                $CURL -H "Content-Type: application/json" --data-binary @- "$CFG_webhook_url" > /dev/null
            ;;
        *)
            report "Unknown service: $CFG_service"; return 1 ;;
    esac
    rc=$?
    if [ $rc -eq 0 ]; then
        report "Last sent ($CFG_service): $2"
    else
        report "Could not reach $CFG_service (curl error $rc)"
    fi
    return $rc
}

load_config
report "Watching prints, sending with $CFG_service"
if is_true "$CFG_test_on_start"; then
    send test "Notifications are on" "Boomslang will tell you here when your prints start, pause, finish or fail."
fi

prev_state=
last_step=0
while true; do
    load_config && say "settings reloaded (service: $CFG_service)"

    json=$(curl -s -m 5 "$MOONRAKER_URL/printer/objects/query?print_stats&display_status&virtual_sdcard")
    fields=$(echo "$json" | jq -r '.result.status as $s |
        "state=\($s.print_stats.state // "" | @sh) file=\($s.print_stats.filename // "" | @sh) " +
        "duration=\($s.print_stats.print_duration // 0 | floor) " +
        "error=\($s.print_stats.message // "" | @sh) " +
        "progress=\((($s.display_status.progress // $s.virtual_sdcard.progress // 0) * 100) | floor)"' 2> /dev/null)
    if [ -z "$fields" ]; then
        sleep "$POLL_INTERVAL"
        continue
    fi
    eval "$fields"
    name=${file##*/}

    # The first reading only sets the baseline: no message after a reboot
    if [ -n "$prev_state" ] && [ "$state" != "$prev_state" ]; then
        case "$state" in
            printing)
                if [ "$prev_state" = "paused" ]; then
                    is_true "$CFG_on_pause" && send resumed "Print resumed" "$name is printing again ($progress %)."
                else
                    last_step=0
                    is_true "$CFG_on_start" && send started "Print started" "$name"
                fi
                ;;
            paused)
                is_true "$CFG_on_pause" && send paused "Print paused" "$name is paused at $progress %."
                ;;
            complete)
                is_true "$CFG_on_complete" && send complete "Print finished" "$name finished in $(human_time "$duration")."
                ;;
            error)
                is_true "$CFG_on_error" && send error "Print failed" "$name stopped at $progress %: ${error:-unknown error}"
                ;;
            cancelled)
                is_true "$CFG_on_error" && send cancelled "Print cancelled" "$name was cancelled at $progress %."
                ;;
        esac
    fi

    step=${CFG_progress_step:-0}
    case "$step" in ''|*[!0-9]*) step=0 ;; esac
    if [ "$state" = "printing" ] && [ "$step" -gt 0 ] && [ "$progress" -lt 100 ]; then
        reached=$((progress / step * step))
        if [ "$reached" -gt "$last_step" ]; then
            [ "$last_step" -gt 0 ] || [ "$prev_state" = "printing" ] && \
                send progress "$reached % done" "$name is at $reached %, printing for $(human_time "$duration")."
            last_step=$reached
        fi
    fi

    prev_state=$state
    sleep "$POLL_INTERVAL"
done
