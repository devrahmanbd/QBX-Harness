# checks/S1-sip-listeners.sh
# memory-query: sip listeners ports ss bind
# timeout: 20
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require ss S1
tcp=$("${HOST_NS[@]}" ss -ltn); udp=$("${HOST_NS[@]}" ss -lun)
ip="${S1_IP:-88.99.250.99}"; miss=""
for p in 5060 5080 5061 5067 7443; do grep -q "$ip:$p" <<<"$tcp" || miss="$miss tcp$p"; done
grep -q "$ip:5060" <<<"$udp" || miss="$miss udp5060"
[ -n "$miss" ] && emit S1 1 "missing listeners:${miss}"
emit S1 0 "all listeners present on $ip (tcp 5060/5080/5061/5067/7443, udp 5060)"
