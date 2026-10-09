# checks/C4-credential-posture.sh
# memory-query: credential hygiene password emitter directory secrets logs scan
# timeout: 60
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require grep C4; require docker C4
# C4 is posture-assert, never absence-assert: the directory channel legitimately
# emits password= (mod_sofia needs it). (a) The ONLY password= emission site in
# FS-serving code is writeDirectoryUser, called solely via the HandleFSDirectory
# path. (b) No secret VALUE appears in the scanned served surfaces (rendered
# profile configs, entrypoint, recent FS logs). Counts never values.
# C4_SRC / C4_SCAN_DIR / C4_SECRETS_FILE inject fixtures for tests.
src="${C4_SRC:-/root/QBX/backend/services/api-gateway/internal/freeswitchresolver}"
[ -d "$src" ] || emit C4 3 "render source missing: $src"
gofiles=$(ls "$src"/*.go | grep -v '_test\.go$')
sites=$(grep -rn '"password"' $gofiles /root/QBX/backend/services/api-gateway/internal/handler/freeswitch.go \
  /root/QBX/backend/services/api-gateway/internal/handler/sync.go 2>/dev/null | grep -vE ':[[:space:]]*//' || true)
n=$(printf '%s' "$sites" | grep -c . || true)
[ "$n" = 1 ] || emit C4 1 "password= emitters != 1 allowlisted site (n=$n): $(printf '%s' "$sites" | head -2 | tr '\n' ' ')"
emitters=$(awk 'FNR==1{fn=""} /^func /{fn=$2; sub(/\(.*/, "", fn)} /"password"/ && !/^[[:space:]]*\/\// {print fn}' $gofiles \
  /root/QBX/backend/services/api-gateway/internal/handler/freeswitch.go \
  /root/QBX/backend/services/api-gateway/internal/handler/sync.go 2>/dev/null | sort -u | tr '\n' ' ')
[ "$emitters" = "writeDirectoryUser " ] || \
  emit C4 1 "password= emitters != allowlisted writeDirectoryUser (found: ${emitters:-none}): $(printf '%s' "$sites" | head -2 | tr '\n' ' ')"
grep -q 'SectionDirectory' /root/QBX/backend/services/api-gateway/internal/handler/freeswitch.go \
  || emit C4 1 "HandleFSDirectory path broken (no SectionDirectory)"
TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
chmod 700 "$TD"; sec="$TD/corpus-ext"; mc="$TD/corpus-mc"; : >"$mc"
if [ -n "${C4_SECRETS_FILE:-}" ]; then
  [ -f "$C4_SECRETS_FILE" ] || emit C4 3 "secrets fixture missing"
  grep -E '.{8,}' "$C4_SECRETS_FILE" >"$sec" 2>/dev/null || true
else
  "${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX \
    -c "SELECT secret FROM extensions WHERE length(secret)>=8" >"$TD/ext" 2>/dev/null \
    || emit C4 3 "extension secrets query failed"
  grep -h '^FREESWITCH_XML_CURL_PASSWORD=' /root/QBX/.env | cut -d= -f2- >"$TD/mc" 2>/dev/null || true
  grep -E '.{8,}' "$TD/ext" >"$sec" || true
  grep -E '.{32,}' "$TD/mc" >"$mc" || true
  [ -s "$mc" ] || emit C4 3 "empty machine-credential corpus"
fi
chmod 600 "$sec" "$mc"
[ -s "$sec" ] || emit C4 3 "empty secrets corpus (nothing to scan for)"
scandir="${C4_SCAN_DIR:-}"
hits=0; files=0
if [ -n "$scandir" ]; then
  [ -d "$scandir" ] || emit C4 3 "scan dir missing: $scandir"
  hits=0; files=0
  while IFS= read -r f; do
    files=$((files+1))
    c=$(grep -cF -f "$sec" "$f" 2>/dev/null || true); c=${c:-0}
    hits=$((hits+c))
  done < <(find "$scandir" -type f 2>/dev/null)
  [ "$hits" -gt 0 ] && emit C4 1 "secret value in scanned configs: files=$files hits=$hits (values withheld)"
  nx=$(wc -l <"$sec" | tr -d ' ')
  emit C4 0 "credential posture holds: 1 allowlisted emitter; 0 secret values in fixture scan (files=$files corpus=$nx)"
else
  # Split corpus: tenant extension secrets must appear NOWHERE in served
  # surfaces. The xml_curl machine credential lives by design in
  # xml_curl.conf.xml gateway-credentials (its documented home, allowlisted);
  # it must appear nowhere else, and its presence at home proves the scan
  # isn't blind (validity control).
  home=/etc/freeswitch/autoload_configs/xml_curl.conf.xml
  prof=$(docker exec -i "${FS_CONTAINER:-telecom-freeswitch-1}" grep -rF -f /dev/stdin /etc/freeswitch 2>/dev/null <"$sec" | wc -l)
  [ "${prof:-0}" = 0 ] || emit C4 1 "tenant secret in rendered FS configs: hits=$prof (values withheld)"
  away=$(docker exec -i "${FS_CONTAINER:-telecom-freeswitch-1}" grep -rF -f /dev/stdin /etc/freeswitch 2>/dev/null <"$mc" | grep -v "^$home" | wc -l)
  [ "${away:-0}" = 0 ] || emit C4 1 "machine credential outside its documented config: hits=$away (values withheld)"
  athome=$(docker exec -i "${FS_CONTAINER:-telecom-freeswitch-1}" grep -cF -f /dev/stdin "$home" 2>/dev/null <"$mc" || true)
  [ "${athome:-0}" -ge 1 ] || emit C4 3 "machine credential absent from $home (scan validity failed)"
  logs=$(docker logs --tail 3000 "${FS_CONTAINER:-telecom-freeswitch-1}" 2>/dev/null | grep -cF -f "$sec" || true)
  [ "${logs:-0}" = 0 ] || emit C4 1 "tenant secret in FS logs: hits=$logs (values withheld)"
  logs_mc=$(docker logs --tail 3000 "${FS_CONTAINER:-telecom-freeswitch-1}" 2>/dev/null | grep -cF -f "$mc" || true)
  [ "${logs_mc:-0}" = 0 ] || emit C4 1 "machine credential in FS logs: hits=$logs_mc (values withheld)"
  ep=$(grep -cF -f "$sec" /root/QBX/deploy/freeswitch/entrypoint.sh 2>/dev/null || true)
  [ "${ep:-0}" = 0 ] || emit C4 1 "tenant secret in entrypoint (values withheld)"
fi
nx=$(wc -l <"$sec" | tr -d ' ')
emit C4 0 "credential posture holds: 1 allowlisted emitter (writeDirectoryUser via HandleFSDirectory); tenant secrets 0 hits everywhere (n=$nx); machine credential only in xml_curl.conf.xml ($athome hits) + 0 in logs"
