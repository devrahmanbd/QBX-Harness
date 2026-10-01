# checks/H2-host-resources.sh
# memory-query: host resources load memory disk oom
# timeout: 20
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require awk H2; require df H2; require nproc H2; require journalctl H2
load1=$(awk '{print $1}' /proc/loadavg); ncpu=$(nproc)
mem_kb=$(awk '/MemAvailable/{print $2}' /proc/meminfo)
disk_pct=$(df -P / | awk 'NR==2{gsub("%","");print $5}')
oom=$(journalctl -k --since "${H2_SINCE:--24h}" --no-pager 2>/dev/null | grep -ciE 'out of memory|oom-kill' || true)
case "$load1" in ''|*[!0-9.]*|*.*.*) emit H2 3 "could not read load1 from /proc/loadavg";; esac
case "$ncpu" in ''|*[!0-9]*) emit H2 3 "could not read cpu count";; esac
case "$mem_kb" in ''|*[!0-9]*) emit H2 3 "could not read MemAvailable from /proc/meminfo";; esac
case "$disk_pct" in ''|*[!0-9]*) emit H2 3 "could not read root filesystem usage";; esac
case "$oom" in ''|*[!0-9]*) emit H2 3 "could not read kernel OOM event count";; esac
load_max=${H2_LOAD_MAX:-$((ncpu*2))}; mem_min=${H2_MEM_MIN_KB:-1048576}; disk_max=${H2_DISK_MAX_PCT:-90}
bad=""
[ "${load1%.*}" -gt "$load_max" ] && bad="load1=$load1 > $load_max"
[ "$mem_kb" -lt "$mem_min" ] && bad="$bad mem_available_kb=$mem_kb < $mem_min"
[ "$disk_pct" -gt "$disk_max" ] && bad="$bad disk_pct=$disk_pct > $disk_max"
[ "${oom:-0}" -gt 0 ] && bad="$bad oom_events=$oom (want 0)"
if [ -n "$bad" ]; then emit H2 1 "breach:${bad# }"; fi
emit H2 0 "load1=$load1/$load_max mem_kb=$mem_kb disk_pct=$disk_pct oom24h=$oom"
