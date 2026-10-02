#!/usr/bin/env bash
# lib/common.sh — shared check contract. Source, don't execute.
set -uo pipefail
HARNESS_ROOT="${HARNESS_ROOT:-/root/qbx-harness}"
HOST_NS=(nsenter -t 1 -n)
[ -f "$HARNESS_ROOT/.env" ] && while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue;; esac
  line="${line#export }"
  case "$line" in *=*) :;; *) continue;; esac
  k="${line%%=*}"
  case "$k" in ''|[0-9]*|*[!A-Za-z0-9_]*) continue;; esac
  [ -n "${!k+x}" ] && continue
  export "$line"
done < "$HARNESS_ROOT/.env"
redact() { sed -E \
  -e 's/((PASSWORD|TOKEN|SECRET|API_KEY|EXT_SECRET|JWT)[_A-Z]*)=[^[:space:]",}]+/\1=<redacted>/Ig' \
  -e 's/"([_A-Z0-9]*(PASSWORD|TOKEN|SECRET|API_KEY|EXT_SECRET|JWT)[_A-Z]*)"([[:space:]]*:[[:space:]]*)"[^"]*"/"\1": "<redacted>"/Ig' \
  -e 's/((PASSWORD|TOKEN|SECRET|API_KEY|EXT_SECRET|JWT)[_A-Z]*)[[:space:]]*:[[:space:]]*[^[:space:]",}]+/\1: <redacted>/Ig' \
  -e 's/(Authorization:[[:space:]]*(Bearer|Token)[[:space:]]+)[^[:space:]"]+/\1<redacted>/Ig'; }
emit() {  # emit <check-id> <exit> <evidence...>  — the ONLY stdout of a check
  local id="$1" code="$2"; shift 2
  local ev; ev=$(printf '%s' "$*" | tr '\n' ' ' | cut -c1-3500)
  ev=$(printf '%s' "$ev" | redact)
  jq -cn --arg check "$id" --argjson exit "$code" --arg e "$ev" \
         --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         '{check:$check,exit:$exit,evidence:($e|.[0:3500]),ts:$ts}'
  exit "$code"; }
require() { command -v "$1" >/dev/null 2>&1 || emit "$2" 3 "required tool missing: $1"; }
esl() { "${HOST_NS[@]}" python3 /root/esl_api.py "$1"; }
run_to() { local s="$1"; shift; timeout "$s" "$@"; }   # 124 → caller emits 3
