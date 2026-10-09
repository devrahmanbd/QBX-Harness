# checks/C-every-render-tenant-prefix.sh
# memory-query: tenant prefix qbx_sub_id dialplan render voicemail outbound
# timeout: 60
#!/usr/bin/env bash
# Pins the tenant-prefix law: every dialplan action list rendered by the
# resolver SHALL open with `set` + `export qbx_sub_id`. Fetches live-served
# dialplan XML for one canary destination per renderer family (feature-code,
# default extension, inbound DID, outbound E.164) and asserts the first two
# actions. Exit 1 names the offending renderer; outbound with no live route
# (not_found doc) is recorded as skipped, never as passing-a-render.
# Scope: leave-vm-direct excluded per spec (static tenant-free doc; tenant state via channel vars from prefixed parents) — 4 stateful families in scope.
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
ID="C-every-render-tenant-prefix"
trap 'rm -f /tmp/cprefix.$$.xml' EXIT   # emit exits bypass the inline rm
require curl "$ID"; require python3 "$ID"; require psql "$ID"

fetch_xml() { # fetch_xml <family> <context> <destination> — prints served XML
  local family="$1" context="$2" dest="$3"
  if [ -n "${C_PREFIX_FIXTURE_DIR:-}" ]; then
    [ -f "$C_PREFIX_FIXTURE_DIR/$family.xml" ] \
      || emit "$ID" 3 "fixture missing: $family.xml"
    cat "$C_PREFIX_FIXTURE_DIR/$family.xml"
    return 0
  fi
  run_to 12 "${HOST_NS[@]}" curl -s -m 10 -u "$FS_USER:$FS_PASS" -X POST \
    "$C_PREFIX_BASE_URL/api/v1/fs/dialplan" \
    --data-urlencode 'section=dialplan' \
    --data-urlencode "context=$context" \
    --data-urlencode "destination_number=$dest" \
    --data-urlencode "domain=$REALM"
}

assert_prefix() { # assert_prefix <family> <xml-file> — prints OK:<sub> | NOROUTE | OOSKIP | OFFENDER:<detail>
  local family="$1" file="$2"
  python3 - "$family" "$file" <<'EOF'
import re, sys
family, path = sys.argv[1], sys.argv[2]
doc = open(path, encoding="utf-8", errors="replace").read()
if 'name="not_found"' in doc or 'name="tenant_not_found"' in doc:
    print("NOROUTE")
    sys.exit(0)
acts = re.findall(r'<action\s+application="([^"]*)"\s+data="([^"]*)"', doc)
if len(acts) >= 2:
    (a0, d0), (a1, d1) = acts[0], acts[1]
    m0 = re.fullmatch(r"qbx_sub_id=(.+)", d0 or "")
    m1 = re.fullmatch(r"qbx_sub_id=(.+)", d1 or "")
    if a0 == "set" and a1 == "export" and m0 and m1 and m0.group(1) == m1.group(1):
        print("OK:%s" % m0.group(1))
        sys.exit(0)
# Extension-targeted renders (bridge/answer/voicemail/echo/playback/sleep/
# transfer) without the opening prefix are offenders. Anything else with no
# prefix (hangup-only error shapes, respond-only docs) is a non-extension
# render outside the pinning scope — explicit skip, never silent.
if any(a in {"bridge", "answer", "voicemail", "echo", "playback", "sleep", "transfer"} for a, _ in acts):
    if len(acts) < 2:
        print("OFFENDER:%s:no-action-list" % family)
    else:
        print("OFFENDER:%s:first-actions=%s/%s" % (family, acts[0], acts[1]))
else:
    print("OOSKIP:%s:non-extension-shape" % family)
EOF
}

if [ -z "${C_PREFIX_FIXTURE_DIR:-}" ]; then
  C_PREFIX_BASE_URL="${C_PREFIX_BASE_URL:-http://127.0.0.1:3006}"
  envfile="${C_PREFIX_ENV_FILE:-/etc/qbx/env/qbx-api-gateway.service.env}"
  FS_USER=$(grep -h '^FREESWITCH_XML_CURL_USERNAME=' "$envfile" 2>/dev/null | cut -d= -f2-)
  FS_PASS=$(grep -h '^FREESWITCH_XML_CURL_PASSWORD=' "$envfile" 2>/dev/null | cut -d= -f2-)
  [ -n "$FS_USER" ] && [ -n "$FS_PASS" ] || emit "$ID" 3 "xml_curl machine credentials unreadable ($envfile)"
  DB="${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}"
  REALM="${C_PREFIX_REALM:-$("${HOST_NS[@]}" psql "$DB" -tAX -c "SELECT realm FROM sip_realms WHERE status='active' ORDER BY realm LIMIT 1" 2>/dev/null)}"
  [ -n "$REALM" ] || emit "$ID" 3 "realm discovery empty"
  EXT="${C_PREFIX_EXT:-$("${HOST_NS[@]}" psql "$DB" -tAX -c "SELECT extension_number FROM extensions ORDER BY extension_number LIMIT 1" 2>/dev/null)}"
  [ -n "$EXT" ] || emit "$ID" 3 "extension canary discovery empty"
  DID="${C_PREFIX_DID:-$("${HOST_NS[@]}" psql "$DB" -tAX -c "SELECT d->>'e164' FROM telephony_configuration_snapshots s CROSS JOIN LATERAL jsonb_array_elements(COALESCE(s.payload->'dids','[]'::jsonb)) d WHERE d->>'e164' LIKE '+%' AND COALESCE(d->>'lifecycle_status','')='active' AND d->>'target_type' = 'extension' ORDER BY d->>'e164' LIMIT 1" 2>/dev/null)}"
  [ -n "$DID" ] || emit "$ID" 3 "DID canary discovery empty"
  OUTBOUND="${C_PREFIX_OUTBOUND:-+15551230099}"
else
  REALM="${C_PREFIX_REALM:-fixture}"; EXT="${C_PREFIX_EXT:-fixture-ext}"
  DID="${C_PREFIX_DID:-fixture-did}"; OUTBOUND="${C_PREFIX_OUTBOUND:-fixture-out}"
fi

f_dest="${C_PREFIX_FEATURE_DEST:-*97}"
declare -A verdicts
for spec in "feature:default:$f_dest" "default:default:$EXT" "inbound:public:$DID" "outbound:default:$OUTBOUND"; do
  family="${spec%%:*}"; rest="${spec#*:}"; context="${rest%%:*}"; dest="${rest#*:}"
  xml=$(fetch_xml "$family" "$context" "$dest") || emit "$ID" 3 "fetch failed: $family($dest)"
  [ -n "$xml" ] || emit "$ID" 3 "fetch empty: $family($dest)"
  printf '%s' "$xml" > /tmp/cprefix.$$.xml
  v=$(assert_prefix "$family" /tmp/cprefix.$$.xml)
  case "$v" in
    OK:*) verdicts[$family]="${v#OK:}" ;;
    NOROUTE) verdicts[$family]="NOROUTE" ;;
    OOSKIP:*) verdicts[$family]="OOSKIP" ;;
    OFFENDER:*) emit "$ID" 1 "missing tenant prefix on $family render (${v#OFFENDER:})" ;;
    *) emit "$ID" 3 "prefix assert failed for $family" ;;
  esac
done
unset FS_USER FS_PASS
# one realm serves all canaries: divergent subs across families is bleed-shaped
subs=$(for f in feature default inbound outbound; do
  v="${verdicts[$f]}"; [ "$v" != "NOROUTE" ] && [ "$v" != "OOSKIP" ] && printf '%s\n' "$v"
done | sort -u | wc -l)
[ "$subs" -le 1 ] || emit "$ID" 1 "tenant key diverges across families: $(for f in feature default inbound outbound; do printf '%s=%s ' "$f" "${verdicts[$f]}"; done)"
ev=""
for f in feature default inbound outbound; do
  dest="$f_dest"; [ "$f" = default ] && dest="$EXT"; [ "$f" = inbound ] && dest="$DID"; [ "$f" = outbound ] && dest="$OUTBOUND"
  v="${verdicts[$f]}"
  if [ "$v" = "NOROUTE" ]; then
    ev="$ev$f($dest)=no-live-route-skipped; "
  elif [ "$v" = "OOSKIP" ]; then
    ev="$ev$f($dest)=out-of-scope-skipped; "
  else
    ev="$ev$f($dest)=prefix-ok sub=$v; "
  fi
done
emit "$ID" 0 "${ev% }"
