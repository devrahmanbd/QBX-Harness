# checks/C-realm-allowlist.sh
# memory-query: sip realm allowlist canonicalRealm challenge-realm registration domain
# timeout: 40
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require grep C-realm
# Renders serve only allowlisted realms: empty realm rejected (canonicalRealm),
# dialplan validates against sip_realms (RealmExists gate), profiles pin a
# challenge-realm. Live: both profiles challenge auto_*; active realm count quoted.
src="${C_REALM_SRC:-/root/QBX/backend/services/api-gateway/internal/freeswitchresolver}"
[ -d "$src" ] || emit C-realm 3 "render source missing: $src"
gofiles=$(ls "$src"/*.go | grep -v '_test\.go$')
grep -q 'realm is required' $gofiles || emit C-realm 1 "canonicalRealm empty-realm reject missing"
gate=$(grep -h 'RealmExists' $gofiles | grep -c . || true)
[ "$gate" -ge 2 ] || emit C-realm 1 "sip_realms allowlist gate missing (refs=$gate, want decl+use)"
grep -q 'func CanonicalSIPRealm' /root/QBX/backend/pkg/telecom/*.go || emit C-realm 3 "CanonicalSIPRealm missing in pkg/telecom"
grep -q 'challenge-realm' /root/QBX/deploy/freeswitch/entrypoint.sh || emit C-realm 1 "no challenge-realm pin in entrypoint"
ext_prof=$(esl "sofia status profile external" 2>/dev/null) || emit C-realm 3 "external profile status unreadable"
int_prof=$(esl "sofia status profile internal" 2>/dev/null) || emit C-realm 3 "internal profile status unreadable"
for p in "$ext_prof" "$int_prof"; do
  cr=$(grep -m1 -i 'challenge realm' <<<"$p" | awk '{print $NF}')
  case "$cr" in auto_from|auto_to|auto_both) : ;; *) emit C-realm 1 "foreign challenge realm live: ${cr:-unreadable}" ;; esac
done
n=$("${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX \
  -c "SELECT count(*) FROM sip_realms WHERE status='active'" 2>/dev/null) || emit C-realm 3 "sip_realms query failed"
emit C-realm 0 "realm allowlist holds: canonical+sip_realms gates present; challenge-realm auto_* both profiles; active-realms=$n"
