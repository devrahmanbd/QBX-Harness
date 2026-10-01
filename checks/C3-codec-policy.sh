# checks/C3-codec-policy.sh
# memory-query: codec policy absolute_codec_string secure media
# timeout: 30
#!/usr/bin/env bash
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"; . "$HARNESS_ROOT/lib/common.sh"
require grep C3
dir="${C2_SCAN_DIR:-/root/QBX}"
target="$dir"; [ -n "${C3_ONLY:-}" ] && target="$dir/$C3_ONLY"
# *_test.go files furnish policy fixtures (forbidden-input strings) — C3 audits production codec policy only.
# NOTE: --include MUST precede --exclude here: with GNU grep 3.11, --exclude listed first silently disables --include.
vals=$(grep -rhoE --include='*.go' --exclude='*_test.go' 'absolute_codec_string=[^"}]+' "$target" 2>/dev/null | sort -u)
base='OPUS,G722,PCMU,PCMA'
grep -qF "$base" <<<"$vals" || \
  emit C3 1 "codec set missing base [$base]: [$(printf '%s' "$vals" | tr '\n' ';')]"
grep -qiE --exclude='*_test.go' 'G729|G723|ILBC' <<<"$vals" && \
  emit C3 1 "forbidden codec token in [$(printf '%s' "$vals" | tr '\n' ';')]"
secure=$(grep -rEoh --include='*.go' --exclude='*_test.go' 'rtp_secure_media=mandatory' "$target" 2>/dev/null | wc -l)
[ "$secure" -ge 1 ] || emit C3 1 "rtp_secure_media=mandatory absent"
emit C3 0 "codec base [$base] present; forbidden tokens G729/G723/ILBC: 0; rtp_secure_media=mandatory hits=$secure"
