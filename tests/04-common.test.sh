# tests/04-common.test.sh
#!/usr/bin/env bash
set -uo pipefail
export H=/root/qbx-harness
t4=$(mktemp -d); trap 'rm -rf "$t4" /tmp/h2-*.json /tmp/h3.json' EXIT
# 1) emit produces parseable JSON and redacts planted secrets
line=$(bash -c 'HARNESS_ROOT='"$H"'; . "$H/lib/common.sh"; emit T0 1 "pw=FREESWITCH_ESL_PASSWORD=hunter2 Authorization: Bearer abc123token"' 2>&1); rc=$?
[ "$rc" -eq 1 ] || { echo "emit rc=$rc"; exit 1; }
printf '%s' "$line" | jq -e '.check=="T0" and .exit==1' >/dev/null || { echo "not JSON: $line"; exit 1; }
case "$line" in *hunter2*|*abc123token*) echo "secret leaked: $line"; exit 1;; esac
printf '%s' "$line" | grep -q '<redacted>' || { echo "redaction marker missing"; exit 1; }
# JSON double-quoted form must redact too
jline=$(bash -c 'HARNESS_ROOT='"$H"'; . "$H/lib/common.sh"; emit T0 1 "{\"ESL_PASSWORD\":\"hunter2\"}"' 2>&1); jrc=$?
[ "$jrc" -eq 1 ] || { echo "json emit rc=$jrc"; exit 1; }
case "$jline" in *hunter2*) echo "json secret leaked: $jline"; exit 1;; esac
printf '%s' "$jline" | grep -q '<redacted>' || { echo "json redaction marker missing: $jline"; exit 1; }
# 2) H2 red-forced by env, green with defaults
H2_LOAD_MAX=0 bash "$H/checks/H2-host-resources.sh" >/tmp/h2-red.json; [ $? -eq 1 ] || { echo "H2 red-forced should be 1"; exit 1; }
grep -q 'load1' /tmp/h2-red.json || { echo "H2 evidence must name load1"; exit 1; }
bash "$H/checks/H2-host-resources.sh" >/tmp/h2-green.json; [ $? -eq 0 ] || { echo "H2 default should pass: $(cat /tmp/h2-green.json)"; exit 1; }
# 3) H4 red-forced, green at 22d
H4_MIN_DAYS=999999 bash "$H/checks/H4-tls-certs.sh" >/dev/null 2>&1; [ $? -eq 1 ] || { echo "H4 red-forced should be 1"; exit 1; }
bash "$H/checks/H4-tls-certs.sh" >/dev/null 2>&1; [ $? -eq 0 ] || { echo "H4 default should pass"; exit 1; }
# 4) missing tool -> error(3), never a crash
for b in bash jq sed tr cut date grep pgrep; do ln -s "$(command -v "$b")" "$t4/$b"; done
out=$(PATH="$t4" bash "$H/checks/H1-process-container.sh" 2>&1); [ $? -eq 3 ] || { echo "H1 no-tool should be 3: $out"; exit 1; }
printf '%s' "$out" | grep -q 'required tool missing' || { echo "H1 evidence lacks reason"; exit 1; }
# 5) H3 live
bash "$H/checks/H3-firewall-surface.sh" >/tmp/h3.json 2>&1; [ $? -eq 0 ] || { echo "H3 should pass: $(cat /tmp/h3.json)"; exit 1; }
# redaction pins (review Critical 1): value classes must stop at structural chars
# 6a) KEY=value inside a compact single-line JSON record: record survives, secret gone
jl=$(bash -c 'HARNESS_ROOT='"$H"'; . "$H/lib/common.sh"; printf "%s" "{\"check\":\"T0\",\"exit\":1,\"evidence\":\"pw=FREESWITCH_ESL_PASSWORD=hunter2\",\"ts\":\"x\"}" | redact' 2>&1)
case "$jl" in *hunter2*) echo "compact json secret leaked: $jl"; exit 1;; esac
printf '%s' "$jl" | grep -q '<redacted>' || { echo "compact json redaction marker missing: $jl"; exit 1; }
printf '%s' "$jl" | jq -e '.check=="T0" and .exit==1 and .ts=="x"' >/dev/null || { echo "KEY=value redact destroyed record: $jl"; exit 1; }
# 6b) Bearer form inside a compact record: token gone, closing quote/brace intact
jl=$(bash -c 'HARNESS_ROOT='"$H"'; . "$H/lib/common.sh"; printf "%s" "{\"evidence\":\"Authorization: Bearer abc123token\",\"ts\":\"y\"}" | redact' 2>&1)
case "$jl" in *abc123token*) echo "bearer record leaked: $jl"; exit 1;; esac
printf '%s' "$jl" | jq -e '.ts=="y"' >/dev/null || { echo "Bearer redact destroyed record: $jl"; exit 1; }
# 6c) KEY: value (colon form) inside a compact record: value bounded by structural chars
jl=$(bash -c 'HARNESS_ROOT='"$H"'; . "$H/lib/common.sh"; printf "%s" "{\"evidence\":\"EXT_SECRET: hunter2\",\"ts\":\"z\"}" | redact' 2>&1)
case "$jl" in *hunter2*) echo "colon-form secret leaked: $jl"; exit 1;; esac
printf '%s' "$jl" | jq -e '.ts=="z"' >/dev/null || { echo "colon-form redact destroyed record: $jl"; exit 1; }
echo ok
