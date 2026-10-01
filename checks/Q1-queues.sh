# checks/Q1-queues.sh
# memory-query: queues ring strategy fifo callcenter
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require systemctl Q1
systemctl is-active --quiet qbx-queue.service || emit Q1 1 "qbx-queue.service not active: $(systemctl is-active qbx-queue.service 2>&1)"
db=$("${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX \
  -c "SELECT count(*) || ' queues: ' || coalesce(string_agg(name||'/'||strategy, ','), 'none configured') FROM queues" 2>/dev/null) \
  || emit Q1 3 "queues table query failed"
# NOTE: esl() is a shell function; timeout(1) cannot exec functions, so inline its body here, interpolating the shared ${HOST_NS[*]} array.
fifo=$(run_to 15 bash -c "exec ${HOST_NS[*]} python3 /root/esl_api.py 'fifo list'" 2>/dev/null | tr '\n' ' ')
grep -qi 'ringall' <<<"$fifo" || emit Q1 1 "fifo list lacks ringall strategy: $(cut -c1-300 <<<"$fifo")"
emit Q1 0 "service=active; $db; fifo ringall present sample=$(cut -c1-120 <<<"$fifo")"
