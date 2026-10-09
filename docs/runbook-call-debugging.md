# Runbook: Call-Debugging Flow (book-driven-telephony-hardening Task 4.1)

Read-only triage for a reported bad call (no answer, one-way audio, early hangup).
Every command below was executed read-only on 2026-10-09 except where marked WRITE.

## 0. Safety gates (no exceptions)

- `nsenter -t 1 -n python3 /root/esl_api.py "show channels"` — note the total.
  If non-zero and the channels are NOT the reported call, STOP and clear residue first.
- Never `uuid_kill` a channel that is not the reported call (ask the reporter for
  Call-ID / destination / time window first).
- Never `reloadxml`/`rescan`/restart in this flow — that is the sofia-rescan runbook.

## 1. Is the call (or its residue) still up?

```bash
nsenter -t 1 -n python3 /root/esl_api.py "show channels"   # 0 total = nothing live
```

## 2. Dump the leg (live leg only, read-only)

```bash
nsenter -t 1 -n python3 /root/esl_api.py "uuid_dump <uuid> json" | jq '{
  state, hangup_cause: .variable_hangup_cause, sip_code: .variable_sip_to_tag,
  secure_media: .variable_rtp_secure_media, codec: .variable_read_codec,
  app: .variable_current_application, dialed: .variable_dialed_extension}'
```

- `hangup_cause` + SIP code classifies the failure (NO_ANSWER/USER_BUSY/UNALLOCATED_NUMBER/NETWORK_ERROR).
- `rtp_secure_media` absent on an outbound bridge leg = codec-policy drift (see C3).
- `current_application` stuck at `bridge` with no ANSWER = carrier never answered (see bridge-failover runbook).

## 3. Correlate with logs (read-only)

```bash
grep -a "^<uuid> " /root/QBX/logs/freeswitch/freeswitch.log | tail -30   # FS leg log
# API side: GET /api/v1/calls/<call_id>/timeline (Bearer + CSRF, see checks/M1-lifecycle.sh)
```

Match FS `CHANNEL_HANGUP_COMPLETE` hangup-cause against the CDR row:

```bash
nsenter -t 1 -n psql "$DATABASE_URL" -c \
  "SELECT status,sip_code,hangup_cause,direction FROM cdrs WHERE call_id='<call_id>'"
```

Missing CDR row for an answered call = D1-class gap; complete-but-unanswered = carrier-side.

## 4. Decide

| Signal | Next runbook |
|---|---|
| `UNALLOCATED_NUMBER`/404 on carrier leg | bridge-failover triage |
| TLS/handshake errors on 5061/7443 | cert rotation |
| Profile missing / gateway gone after config change | sofia rescan procedure |
| No FS log lines for the uuid at all | call never reached FS: check nft (H3) + carrier allowlist (I1) |

## 5. Close out

Record call_id, hangup cause, and verdict in `fixes.log` (append-only). Channels 0 total after.
