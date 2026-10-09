# checks/V3-voicemail-pin-audit.sh
# memory-query: voicemail pin weak audit mailbox bcrypt
# timeout: 60
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require python3 V3
python3 -c 'import bcrypt' 2>/dev/null || emit V3 3 "python bcrypt missing"
# Read-only audit: compare known-weak candidates against stored hashes.
# Counts never values — hashes and PINs never enter evidence.
# V3_FIXTURE_TSV (ext<TAB>hash lines) injects rows for fixture tests.
TD=$(mktemp -d); trap 'rm -rf "$TD"' EXIT
if [ -n "${V3_FIXTURE_TSV:-}" ]; then
  [ -f "$V3_FIXTURE_TSV" ] || emit V3 3 "fixture missing: $V3_FIXTURE_TSV"
  cp "$V3_FIXTURE_TSV" "$TD/rows.tsv"
else
  "${HOST_NS[@]}" psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" -tAX -F'	' \
    -c "SELECT extension_number, COALESCE(voicemail_pin_hash,'') FROM extensions" >"$TD/rows.tsv" 2>/dev/null \
    || emit V3 3 "extensions PIN query failed"
fi
res=$(python3 - "$TD/rows.tsv" <<'EOF' 2>/dev/null || echo "PYFAIL"
import bcrypt, sys
weak = empty = total = 0
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if not line.strip():
        continue
    total += 1
    ext, _, h = line.partition("\t")
    if not h.strip():
        empty += 1
        continue
    for cand in ("1111", "1234", ext.strip()):
        try:
            if bcrypt.checkpw(cand.encode(), h.strip().encode()):
                weak += 1
                break
        except ValueError:
            pass
print("%d %d %d" % (total, weak, empty))
EOF
)
[ "$res" = PYFAIL ] || [ -z "$res" ] && emit V3 3 "PIN audit compute failed"
set -- $res; total=$1; weak=$2; empty=$3
[ "$weak" -gt 0 ] && emit V3 1 "weak mailbox PINs present: weak=$weak of mailboxes=$total (known-weak policy match; values withheld)"
emit V3 0 "pin audit clean: mailboxes=$total weak=0 (known-weak policy) unset-pin=$empty"
