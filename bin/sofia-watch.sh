#!/usr/bin/env bash
# bin/sofia-watch.sh — read-only Sofia gateway + registration exporter.
# Queries ESL (status only, never modifies) and writes a node_exporter
# textfile consumed by /etc/prometheus/rules/qbx-telephony.yml.
# Series: qbx_sofia_gateway_state{gateway,profile} (1=REGED else 0; absent
# when zero gateways are configured — never fires, never pages),
# qbx_sofia_gateway_count, qbx_sofia_registrations{profile},
# qbx_sofia_scrape_ok (1=exporter healthy; drives QBXSofiaExporterStale).
# Run via qbx-sofia-watch.timer (60s). TEXTFILE_DIR overridable for tests.
set -uo pipefail
H="${HARNESS_ROOT:-/root/qbx-harness}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/prometheus/node-exporter}"
ESL_API="${ESL_API:-/root/esl_api.py}"
TMP="${TEXTFILE_DIR}/.qbx-sofia.$$.prom"
OUT_LINES=""
gw_raw=$(nsenter -t 1 -n python3 "$ESL_API" 'sofia status gateway' 2>/dev/null) || gw_raw=""
gw_count=0
if grep -qE '^[[:space:]]*0 gateways' <<<"$gw_raw"; then
  gw_count=0
else
  while IFS= read -r line; do
    # gateway table rows: name ... state ... ; state column holds REGED etc.
    g=$(awk '{print $1}' <<<"$line"); s=$(grep -oE 'REGED|UNREGED|FAILED|NOREG|UNREGISTERED|REGISTERED' <<<"$line" | head -1)
    [ -z "${g:-}" ] || [ -z "${s:-}" ] && continue
    v=0; [ "$s" = "REGED" ] || [ "$s" = "REGISTERED" ] && v=1
    OUT_LINES+=$(printf 'qbx_sofia_gateway_state{gateway="%s",profile="external"} %s' "$g" "$v")$'\n'
    gw_count=$((gw_count+1))
  done < <(grep -vE '^[[:space:]]*$|^=+|Gateway-Name|gateways:' <<<"$gw_raw" | grep -E '[[:alnum:]]' || true)
fi
reg_raw=$(nsenter -t 1 -n python3 "$ESL_API" 'sofia status profile internal reg' 2>/dev/null) || reg_raw=""
regs=$(grep -oE 'Total items returned: [0-9]+' <<<"$reg_raw" | grep -oE '[0-9]+' | tail -1)
[ -z "${regs:-}" ] && regs=-1
{ echo "# HELP qbx_sofia_gateway_state 1 when trunk gateway REGED, else 0."
  echo "# TYPE qbx_sofia_gateway_state gauge"
  [ -n "$OUT_LINES" ] && printf '%s' "$OUT_LINES"
  echo "# HELP qbx_sofia_gateway_count Configured trunk gateways."
  echo "# TYPE qbx_sofia_gateway_count gauge"
  echo "qbx_sofia_gateway_count $gw_count"
  echo "# HELP qbx_sofia_registrations Internal-profile registrations (-1 = unreadable)."
  echo "# TYPE qbx_sofia_registrations gauge"
  echo "qbx_sofia_registrations{profile=\"internal\"} $regs"
  echo "# HELP qbx_sofia_scrape_ok 1 when this exporter ran clean."
  echo "# TYPE qbx_sofia_scrape_ok gauge"
  echo "qbx_sofia_scrape_ok 1"
} > "$TMP" && mv "$TMP" "${TEXTFILE_DIR}/qbx-sofia.prom"
