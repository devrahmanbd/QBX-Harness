# Runbook: Bridge-Failover Triage (book-driven-telephony-hardening Task 4.1)

For outbound bridge failures (carrier leg never answers, `CALL_REJECTED`,
`NETWORK_ERROR`, gateway DOWN). Read-only probes validated 2026-10-09; WRITE
steps marked.

## 0. Safety gates

- `show channels` 0 total before/after (your triage calls excepted, labeled).
- Never `killgw`/delete a trunk file without owner sign-off — a wrong killgw
  drops the carrier path for all 100+ tenants.

## 1. Locate the failure (read-only)

```bash
nsenter -t 1 -n python3 /root/esl_api.py "sofia status gateway"   # want REGED/UP per row; DOWN = carrier path dead
bash checks/I1-carrier-health.sh   # asserts REGED vs DOWN where gateways exist; records opt-out at 0 gateways
nsenter -t 1 -n nft list ruleset | grep -E 'saddr.*dport 5060'     # carrier allowlist present? (H3 asserts)
```

Live 2026-10-09: **0 gateways listed** (no trunk deployed yet) + DIDX nft rule at
0 packets → I1 exit 2 (blocked, awaiting DIDX portal ring-to test). Any bridge
string to `sofia/gateway/*` currently has NO live gateway to bind to.

## 2. Classify

| `sofia status gateway <gw>` | nft carrier counters rising? | Verdict |
|---|---|---|
| REGED/UP | yes | carrier path healthy — failure is dialplan/routing (see call-debugging flow) |
| DOWN/NOREG | yes | carrier rejecting us (auth/IP) — check trunk creds + `ping-frequency` (freeswitch.go always emits it) |
| DOWN/NOREG | no (0 packets) | carrier never heard us — network/allowlist path (H3) or wrong proxy/realm |
| no gateway row at all | — | trunk not deployed — sofia-rescan runbook, then re-triage |

## 3. Failover (WRITE — owner sign-off)

1. Confirm the SIBLING path first: internal extension-to-extension bridge
   (`user/<ext>`) must work — if it doesn't, this is NOT a carrier failover case.
2. `sofia profile external killgw <dead-gw>` + deploy standby trunk file +
   `sofia profile external rescan` (see sofia-rescan runbook).
3. Re-run I1 (REGED/UP) + place ONE labeled test call before declaring recovery.

## 4. Bridge-string audit reference (read-only, no QBX edits)

Outbound carrier bridges exist ONLY in `outboundActions` (C-public pins this);
`GenerateDialplan` emits `sofia/gateway/<gw>/$1` per trunk. No trunk rows are
deployed live, so every carrier bridge currently resolves to no gateway — the
I1 opt-out (`gateways=0`) is the honest signal, not a failure to chase.
