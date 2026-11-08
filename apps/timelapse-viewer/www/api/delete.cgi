#!/bin/sh
# Deletes one timelapse video. Only when allowed in the app settings, only
# POST, and only plain .mp4 file names inside the timelapse folder.
HERE=$(dirname "$SCRIPT_FILENAME")
. "$HERE/../../runtime.env"

reply() {
    echo "Status: $1"
    echo "Content-Type: application/json"
    echo
    jq -n --arg m "$2" '{message: $m}'
    exit 0
}

[ "$REQUEST_METHOD" = "POST" ] || reply "405 Method Not Allowed" "Use POST"
[ "$(jq -r '.allow_delete // "False"' "$USER_CONFIG" 2> /dev/null)" = "True" ] || reply "403 Forbidden" "Deleting is turned off in the app settings"

name=$(head -c "${CONTENT_LENGTH:-0}" | jq -r '.name // empty' 2> /dev/null)
case "$name" in
    ''|*/*|.*|*'\'*) reply "400 Bad Request" "Invalid file name" ;;
    *.mp4) ;;
    *) reply "400 Bad Request" "Only .mp4 files can be deleted" ;;
esac
[ -f "$VIDEO_DIR/$name" ] || reply "404 Not Found" "No such video"

rm -f "$VIDEO_DIR/$name" && sync
reply "200 OK" "Deleted $name"
