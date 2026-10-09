# Originate-Guards Review (book-driven-telephony-hardening Task 4.1)

Read-only audit of every originate/bridge string in QBX code (gateway code NOT
modified). Per string: ping / ignore_early_media / leg_timeout — emit or
recorded opt-out, no silent gaps. Probed 2026-10-09.

Legend: PRESENT = in the string; OPT-OUT(reason) = deliberately absent, recorded.

## Originate strings (bgapi originate / originate)

| # | Site | String shape | ping | ignore_early_media | leg_timeout audit |
|---|---|---|---|---|---|
| O1 | `call-control/internal/commands/commands.go:135` (API originate) | `bgapi originate {qbx_sub_id,qbx_user_id,qbx_trunk_id,origination_caller_id_number,origination_uuid,qbx_call_command_id}user/{ext} &bridge(...)` | OPT-OUT (user-leg originate; ping-frequency lives on trunk GATEWAY defs in `pkg/telecom/freeswitch.go:116`, PRESENT there for every gateway) | OPT-OUT (A-leg rings a registered USER extension; false-answer risk sits on the bridge B-leg, which inherits dialplan `call_timeout=25`) | OPT-OUT bridge-target audit: `&bridge(user\|loopback/...)` — internal legs, bounded by dialplan `call_timeout=25`; no `leg_timeout` needed on user legs |
| O2 | `call-control/callback_worker.go:148` (callback exec, env-gated) | `bgapi originate {qbx_sub_id,qbx_callback*,origination_uuid,origination_caller_id_number}sofia/external/{num} &park` | OPT-OUT (default dialPrefix `sofia/external/` bypasses gateway objects; if a trunk gateway is introduced, its def carries ping-frequency per `GenerateGatewayXML`) | OPT-OUT with RISK NOTE: no `ignore_early_media`; `&park` answers on media, so false-answer exposure is limited to park-time billing — recommend adding `ignore_early_media=true` when this path is next touched | PRESENT-equivalent: park (no bridge timeout semantics); callback attempt bounded by worker retry caps |
| O3 | `call-control/main.go:398` (voicemail operator page) | `bgapi originate {origination_caller_id_name=Voicemail,origination_caller_id_number=VM,origination_timeout=20,hangup_after_bridge=true}user/{mbox}@{domain} &playback(...)` | OPT-OUT (user-leg, same as O1) | OPT-OUT (pages a registered mailbox extension; `&playback` leg, `origination_timeout=20` bounds ring time) | PRESENT (`origination_timeout=20` + `hangup_after_bridge=true`) |
| O4 | `call-control/main.go:588` (voicemail callback) | `originate {qbx_sub_id,origination_caller_id_name/number,origination_timeout=30,hangup_after_bridge=true,ignore_early_media=true}user/{ext}@{domain} &playback(...)` | OPT-OUT (user-leg, same as O1) | PRESENT | PRESENT (`origination_timeout=30` + `hangup_after_bridge=true`) — reference shape |
| O5 | `call-control/main.go:1643` (queue ring-all) | `bgapi originate {ignore_early_media=true,origination_timeout=%d,qbx_dispatch_id,qbx_sub_id}user/{ext} &playback(silence_stream)` | OPT-OUT (user-leg, same as O1) | PRESENT | PRESENT (`origination_timeout=<queue timeout>`) |
| O6 | `call-control/internal/handler/ivr_test_calls.go:66` (IVR test calls) | `bgapi originate {qbx_sub_id,qbx_test_call=true,...,origination_uuid,origination_caller_id_number}user/{from} &bridge(user/{dest})` | OPT-OUT (user-leg, same as O1) | OPT-OUT (test-only, `qbx_test_call=true` isolation mode non_production; bridge target is a test extension) | OPT-OUT (test call bounded by attempt journal + timeout worker; same class as O1) |

## Bridge strings (dialplan renders — leg_timeout audit)

| # | Site | Shape | `originate_continue_on_timeout` / `leg_timeout` |
|---|---|---|---|
| B1 | `freeswitchresolver/resolver.go:1172,1242` (outboundActions bridge) | `bridge {rtp_secure_media=mandatory,absolute_codec_string=...,qbx_dialed_ext=...}${sofia_contact(...)}` | OPT-OUT recorded: neither param present; leg bound by dialplan `call_timeout=25` + `hangup_after_bridge=true` on sibling renders. Recommend `leg_timeout` when multi-gateway failover sequencing lands (see bridge-failover runbook). |
| B2 | `pkg/telecom/dialplan.go` (GenerateExtensionDialplan + GenerateDialplan trunk `sofia/gateway/<gw>/$1`) | `bridge user/...@$${domain}` / `bridge sofia/gateway/...` | OPT-OUT recorded: `call_timeout=25` set on extension legs; trunk legs have no per-leg timeout — same recommendation as B1. No trunk rows deployed live, so currently unreached. |

## Gateway ping (spec: trunk gateways SHALL carry OPTIONS ping)

PRESENT for every gateway: `GenerateGatewayXML` (`pkg/telecom/freeswitch.go:101-116`)
always emits `<param name="ping-frequency" value="30|120"/>` (30 ipauth, 120
registered). No gateway XML constructor bypasses it (single constructor +
`freeswitch_test.go` pins). Live: 0 gateways deployed — nothing to observe yet;
I1 will assert REGED/UP once trunks land.

## Gaps carried forward (emit, not silent)

- O2 should gain `ignore_early_media=true` on next touch (risk note above).
- B1/B2 should gain `leg_timeout` when gateway failover sequencing is built.
- No code changed in this review (gateway code read-only for Task 4).
