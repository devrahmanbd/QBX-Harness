# L2 auth-jail storm-replay proof (Task 6, 2026-10-09)

Jail: `freeswitch-auth` (`/etc/fail2ban/jail.d/freeswitch-auth.conf`,
`enabled=false` — owner enables after this proof).
Filter: `/etc/fail2ban/filter.d/freeswitch-auth.conf`, derived from live
FreeSWITCH 1.10.12 lines, NOT the book's 1.2-era pattern. Live samples:
- `2026-10-09 10:24:37.221843 38.50% [WARNING] sofia_reg.c:3210 Can't find user [4511@88.99.250.99] from 118.89.58.176`
- `2026-10-09 10:24:35.861886 38.00% [WARNING] sofia_reg.c:3210 Can't find user [4919@88.99.250.99] from 5.135.106.93`
- `2026-10-09 10:24:30.381843 38.13% [WARNING] sofia_reg.c:3210 Can't find user [2027@qbx.qubickle.com] from 160.119.76.14`

## Storm math (thresholds: maxretry=30, findtime=300s, bantime=1800s)

- 100 tenants x ~5 endpoints = ~500 re-REGISTERs post-outage. All are KNOWN
  users -> REGISTER succeeds -> no `sofia_reg.c Can't find user` lines from
  the storm itself. Replay measured 459 storm lines / 12 matched (all stale-
  device, below maxretry 30 -> unbanned). Proven safe AT maxretry=30 /
  findtime=300s; any threshold change needs a re-replay before enablement.
- Live attacker per-5min maxima (20h window): 5.135.106.93=177,
  118.89.58.176=102, 82.165.251.107=54, 160.119.76.14=50, 185.243.5.164=46.
  All exceed 30 within one findtime window -> banned during active scans.
- Residual: stale devices (deleted extensions) behind one office NAT, worst
  benign observed ~11 lines/min. Tripping only silences already-failing
  attempts; 1800s auto-unban bounds blast radius. Carrier/trunk IPs must be
  added to ignoreip at enablement.

## Replay (fail2ban-regex 1.0.2, samples in /tmp/opencode/l2proof/)

Samples are SEMI-SYNTHETIC: attack lines carry a doubled percentage prefix
(`38.00% 50.47%`, timestamp compression artifact) and storm NOTICE filler
lines (`Registered user ...`) match no live shape — both deliberate. The
failregex has no start anchor, so the artifact prefix cannot affect matching;
only the `sofia_reg.c ... Can't find user ... from <IP>` core (verbatim live
text) is under test.

Storm sample (459 lines: ~447 legit successful-REGISTER NOTICE lines +
12 stale-device WARNING lines from one office NAT 198.51.100.7 in 5 min):
- `Lines: 459 lines, 0 ignored, 12 matched, 447 missed`
- Max per-IP hits in window: 12 (198.51.100.7) < maxretry 30 -> NO BAN.
  All 447 legit re-register lines unmatched. STORM VERDICT: UNBANNED.

Attack sample (300 lines: 60 densest-window lines each from the 5 live
scanner IPs, each compressed into one 300s findtime window):
- `Lines: 300 lines, 0 ignored, 300 matched, 0 missed`
- Per-IP hits: 60 each, all >= maxretry 30 -> ALL 5 BANNED.
  ATTACK VERDICT: BANNED.

## Live state

- `fail2ban-client reload` parses the new files cleanly (no errors in
  /var/log/fail2ban.log); `fail2ban-client status` still lists only `sshd`.
- Jail NOT enabled live pending owner review (this proof) + ignoreip for
  carrier/trunk sources. L2 check stays red until enablement by design.
- L2 is deliberately NOT in checks/CATALOG yet: an untolerated L2 red would
  page via QBXHarnessRedSweep on every sweep. Add the `L2` CATALOG row in the
  same change that flips the jail to enabled=true.

## Telegram delivery: UNCONFIRMED (owner eyeball step, no test alert fired)

- Per controller ruling 2026-10-09: no test alert is fired (H2 already pages
  genuinely; test alerts are noise). Routing-proof only: alertmanager config
  routes default + critical to the `telegram` receiver (bot token + chat in
  /etc/alertmanager files), and the live QBXHarnessRedSweep/H2 page currently
  active in alertmanager carries `receivers: [telegram]` — same route the
  Task 6 alerts will ride.
- Owner step: open the Telegram chat and confirm (a) the H2
  QBXHarnessRedSweep page arrived (live example of a firing alert), (b) after
  jail enablement, any QBXAuthJailInactive warning arrives with its runbook
  text, (c) healthy silence = no Task 6 alert names (QBXTrunkGatewayDown,
  QBXTelephonyRegistrationsDrop, QBXAuthJailInactive, QBXSofiaExporterStale)
  in chat while `curl localhost:9090/api/v1/alerts` shows none firing.
