#!/bin/sh
# Sends host CPU, load, memory and disk usage to Seq as a structured (CLEF) event every INTERVAL seconds.
# /proc/stat and /proc/meminfo inside a container show the host's values; mount the host root read-only on DISK_PATH.
# With DOCKER_URL set (a docker-socket-proxy), also sends one event per running container.

: "${HOST_NAME:=$(hostname)}"
: "${SEQ_URL:=http://seq:5341}"
: "${SEQ_API_KEY:=}"
: "${INTERVAL:=60}"
: "${WARN_PERCENT:=90}"
: "${DISK_PATH:=/host}"
: "${DOCKER_URL:=}"

cpu_sample() { awk '/^cpu /{ print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6 }' /proc/stat; }

send() {
    if [ -n "$SEQ_API_KEY" ]; then
        curl -sf -m 10 -o /dev/null -X POST "$SEQ_URL/api/events/raw?clef" \
            -H "Content-Type: application/vnd.serilog.clef" -H "X-Seq-ApiKey: $SEQ_API_KEY" --data-binary "$1"
    else
        curl -sf -m 10 -o /dev/null -X POST "$SEQ_URL/api/events/raw?clef" \
            -H "Content-Type: application/vnd.serilog.clef" --data-binary "$1"
    fi
}

# Prints one CLEF event per running container (CPU, memory, writable layer size) from the Docker API on DOCKER_URL.
container_events() {
    dir=$(mktemp -d)
    if ! curl -sf -m 30 -o "$dir/list" "$DOCKER_URL/containers/json?size=true"; then
        echo "$1 reading containers from $DOCKER_URL failed" >&2
        rm -rf "$dir"
        return
    fi
    # stream=false waits ~1s for a second CPU sample, so query all containers in parallel
    for id in $(jq -r '.[].Id' "$dir/list"); do
        curl -sf -m 15 -o "$dir/stats-$id" "$DOCKER_URL/containers/$id/stats?stream=false" &
    done
    wait
    cat "$dir"/stats-* 2>/dev/null | jq -c -s --arg ts "$1" --arg host "$HOST_NAME" --argjson w "$WARN_PERCENT" --slurpfile list "$dir/list" '
        def r(n): . * n | round / n;
        ($list[0] | map({ key: .Id, value: . }) | from_entries) as $info
        | .[] | select(.memory_stats.usage != null and (.memory_stats.limit // 0) > 0 and $info[.id] != null)
        | $info[.id] as $c
        # CPU: share of all host cores, like the host CpuPercent
        | ((.cpu_stats.cpu_usage.total_usage // 0) - (.precpu_stats.cpu_usage.total_usage // 0)) as $cpu
        | ((.cpu_stats.system_cpu_usage // 0) - (.precpu_stats.system_cpu_usage // 0)) as $sys
        | (.cpu_stats.online_cpus // 1) as $cores
        | (if $sys > 0 then $cpu / $sys else 0 end) as $share
        # Memory: same as docker stats (usage minus inactive page cache); limit is host memory when unlimited
        | (.memory_stats.usage - (.memory_stats.stats.inactive_file // .memory_stats.stats.total_inactive_file // 0)) as $mem
        | .memory_stats.limit as $limit
        | { "@t": $ts,
            "@l": (if $share * 100 > $w or $mem * 100 / $limit > $w then "Warning" else "Information" end),
            "@mt": "{Host}/{Container}: CPU {CpuPercent}% | Geheugen {MemUsedMB} MB | Disk {DiskUsedMB} MB",
            Application: "container-metrics",
            Host: $host,
            Container: (.name | ltrimstr("/")),
            Image: $c.Image,
            ComposeProject: ($c.Labels["com.docker.compose.project"] // null),
            CpuPercent: ($share * 100 | r(10)),
            CpuUsedCores: ($share * $cores | r(100)),
            MemUsedMB: ($mem / 1048576 | r(10)),
            MemLimitMB: ($limit / 1048576 | round),
            MemUsedPercent: ($mem * 100 / $limit | r(10)),
            DiskUsedMB: (($c.SizeRw // 0) / 1048576 | r(10)) }
        | with_entries(select(.value != null))'
    rm -rf "$dir"
}

# Running as PID 1: exit on docker stop instead of waiting for the kill timeout
trap 'echo "server-metrics stopped"; exit 0' TERM INT

echo "server-metrics started: $HOST_NAME -> $SEQ_URL every ${INTERVAL}s (disk: $DISK_PATH, containers: ${DOCKER_URL:-off})"
prev=$(cpu_sample)

while true; do
    # sleep in the background so the trap fires immediately
    sleep "$INTERVAL" &
    wait $!

    # CPU: busy share of all jiffies since the previous sample (idle + iowait count as idle)
    cur=$(cpu_sample)
    set -- $prev $cur
    prev=$cur
    cpu=$(awk -v t=$(($3 - $1)) -v i=$(($4 - $2)) 'BEGIN{ printf "%.1f", (t > 0 ? (t - i) * 100 / t : 0) }')
    # Capacity in cores; used cores = share of that capacity
    cpu_cores=$(grep -c '^processor' /proc/cpuinfo)
    cpu_used=$(awk -v p="$cpu" -v n="$cpu_cores" 'BEGIN{ printf "%.2f", p * n / 100 }')

    # Memory: used = total - available (page cache counts as free)
    set -- $(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{ printf "%.0f %.0f %.1f", t/1024, (t-a)/1024, (t-a)*100/t }' /proc/meminfo)
    mem_total=$1; mem_used=$2; mem_pct=$3

    set -- $(df -Pk "$DISK_PATH" | awk 'NR==2{ printf "%.1f %.1f %.1f %.1f", $2/1048576, $3/1048576, $4/1048576, $3*100/($3+$4) }')
    disk_total=$1; disk_used=$2; disk_free=$3; disk_pct=$4

    set -- $(cat /proc/loadavg)
    load1=$1; load5=$2; load15=$3

    level=$(awk -v c="$cpu" -v m="$mem_pct" -v d="$disk_pct" -v w="$WARN_PERCENT" 'BEGIN{ print ((c > w || m > w || d > w) ? "Warning" : "Information") }')
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    event="{\"@t\":\"$ts\",\"@l\":\"$level\",\"@mt\":\"{Host}: CPU {CpuPercent}% | Geheugen {MemUsedPercent}% | Disk vrij {DiskFreeGB} GB\",\"Application\":\"server-metrics\",\"Host\":\"$HOST_NAME\",\"CpuPercent\":$cpu,\"CpuCores\":$cpu_cores,\"CpuUsedCores\":$cpu_used,\"Load1\":$load1,\"Load5\":$load5,\"Load15\":$load15,\"MemTotalMB\":$mem_total,\"MemUsedMB\":$mem_used,\"MemUsedPercent\":$mem_pct,\"DiskTotalGB\":$disk_total,\"DiskUsedGB\":$disk_used,\"DiskFreeGB\":$disk_free,\"DiskUsedPercent\":$disk_pct}"

    send "$event" || echo "$ts sending to Seq failed: $event"

    if [ -n "$DOCKER_URL" ]; then
        events=$(container_events "$ts")
        [ -n "$events" ] && { send "$events" || echo "$ts sending container events to Seq failed"; }
    fi
done
