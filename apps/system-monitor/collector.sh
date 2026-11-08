#!/bin/sh
# System monitor collector for Boomslang. BusyBox ash compatible.
# Every INTERVAL seconds appends one line to metrics.csv; every minute writes
# the top processes to procs.json. Keeps MAX_LINES lines (12 h at 10 s).
# Overridable for testing: DATA_DIR, PROC, SYS, MOONRAKER_URL, DISK_PATH,
# INTERVAL, MAX_LINES, PROC_EVERY

DATA_DIR=${DATA_DIR:-/tmp/system-monitor}
PROC=${PROC:-/proc}
SYS=${SYS:-/sys}
MOONRAKER_URL=${MOONRAKER_URL:-http://127.0.0.1:7125}
DISK_PATH=${DISK_PATH:-/useremain}
INTERVAL=${INTERVAL:-10}
MAX_LINES=${MAX_LINES:-4320}
PROC_EVERY=${PROC_EVERY:-6}
HZ=100
PAGE_KB=4

mkdir -p "$DATA_DIR"
CSV=$DATA_DIR/metrics.csv
[ -s "$CSV" ] || echo "time,cpu,mem_used_mb,mem_avail_mb,mem_total_mb,load1,soc_temp,extruder,bed,disk_pct" > "$CSV"

cpu_ticks() {
    awk '/^cpu /{ idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print total, idle; exit }' "$PROC/stat"
}

write_procs() {
    elapsed=$1
    out=$DATA_DIR/.procs.$$
    # shellcheck disable=SC2086
    cat "$PROC"/[0-9]*/stat 2> /dev/null | awk -v prevfile="$DATA_DIR/.ticks" -v newfile="$DATA_DIR/.ticks.new" \
        -v hz=$HZ -v dt="$elapsed" -v page=$PAGE_KB '
        BEGIN { while ((getline line < prevfile) > 0) { split(line, a, " "); old[a[1]] = a[2] } }
        {
            op = index($0, "(")
            cl = 0
            for (i = length($0); i > op; i--) if (substr($0, i, 1) == ")") { cl = i; break }
            if (!op || !cl) next
            pid = substr($0, 1, op - 2) + 0
            name = substr($0, op + 1, cl - op - 1)
            n = split(substr($0, cl + 2), f, " ")
            ticks = f[12] + f[13]
            rss = f[22] * page
            print pid, ticks > newfile
            cpu = (pid in old && dt > 0) ? (ticks - old[pid]) * 100 / (hz * dt) : 0
            if (cpu < 0) cpu = 0
            count++
            if (rss > 0) printf "%d\t%.1f\t%d\t%s\n", rss, cpu, pid, name
        }
        END { printf "count\t%d\n", count > "/dev/stderr" }' 2> "$out.count" | sort -rn | head -n 15 > "$out"
    mv -f "$DATA_DIR/.ticks.new" "$DATA_DIR/.ticks" 2> /dev/null
    total=$(cut -f2 "$out.count" 2> /dev/null)
    jq -R -s --argjson t "$(date +%s)" --argjson n "${total:-0}" '{
        time: $t, processes: $n,
        top: (split("\n") | map(select(length > 0) | split("\t")
              | {rss_kb: (.[0] | tonumber), cpu: (.[1] | tonumber), pid: (.[2] | tonumber), name: .[3]}))
    }' "$out" > "$DATA_DIR/procs.json.new" && mv -f "$DATA_DIR/procs.json.new" "$DATA_DIR/procs.json"
    rm -f "$out" "$out.count"
}

set -- $(cpu_ticks)
prev_total=$1; prev_idle=$2
last_procs=$(date +%s)
write_procs 0
i=0
while true; do
    sleep "$INTERVAL"
    now=$(date +%s)

    set -- $(cpu_ticks)
    dt=$(($1 - prev_total)); didle=$(($2 - prev_idle))
    prev_total=$1; prev_idle=$2
    cpu=0
    [ "$dt" -gt 0 ] && cpu=$(( (dt - didle) * 1000 / dt ))
    cpu="$((cpu / 10)).$((cpu % 10))"

    mem=$(awk '/^MemTotal:/{ t = $2 } /^MemAvailable:/{ a = $2 } END { printf "%d,%d,%d", (t - a) / 1024, a / 1024, t / 1024 }' "$PROC/meminfo")
    load=$(cut -d' ' -f1 "$PROC/loadavg")
    soc=$(cat "$SYS"/class/thermal/thermal_zone*/temp 2> /dev/null | awk 'BEGIN { m = "" } { if (m == "" || $1 > m) m = $1 } END { if (m != "") printf "%.1f", m / 1000 }')
    temps=$(curl -s -m 2 "$MOONRAKER_URL/printer/objects/query?extruder=temperature&heater_bed=temperature" |
        jq -r '[(.result.status.extruder.temperature // ""), (.result.status.heater_bed.temperature // "")]
               | map(if type == "number" then (. * 10 | round / 10 | tostring) else "" end) | join(",")' 2> /dev/null)
    [ -z "$temps" ] && temps=","
    disk=$(df -P "$DISK_PATH" 2> /dev/null | awk 'NR == 2 { gsub("%", "", $5); print $5 }')

    echo "$now,$cpu,$mem,$load,$soc,$temps,$disk" >> "$CSV"

    i=$((i + 1))
    if [ $((i % PROC_EVERY)) -eq 0 ]; then
        write_procs $((now - last_procs))
        last_procs=$now
    fi
    if [ $((i % 60)) -eq 0 ] && [ "$(wc -l < "$CSV")" -gt $((MAX_LINES + 300)) ]; then
        { head -n 1 "$CSV"; tail -n "$MAX_LINES" "$CSV"; } > "$CSV.new" && mv -f "$CSV.new" "$CSV"
    fi
done
