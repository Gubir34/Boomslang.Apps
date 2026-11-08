#!/bin/sh
# Lists timelapse videos as JSON, newest first
HERE=$(dirname "$SCRIPT_FILENAME")
. "$HERE/../../runtime.env"

allow=false
[ "$(jq -r '.allow_delete // "False"' "$USER_CONFIG" 2> /dev/null)" = "True" ] && allow=true

echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo

for f in "$VIDEO_DIR"/*.mp4; do
    [ -f "$f" ] || continue
    info=$(stat -c '%s %Y' "$f" 2> /dev/null) || info="$(wc -c < "$f") $(date -r "$f" +%s)"
    printf '%s\t%s\n' "${f##*/}" "$info"
done | jq -R -s --argjson allow $allow '{
    allow_delete: $allow,
    videos: (split("\n") | map(select(length > 0) | split("\t") as [$name, $info]
        | ($info | split(" ")) as [$size, $mtime]
        | {name: $name, size: ($size | tonumber), mtime: ($mtime | tonumber)})
        | sort_by(-.mtime))
}'
