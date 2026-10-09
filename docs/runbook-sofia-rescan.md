# Runbook: Sofia Rescan Procedure (book-driven-telephony-hardening Task 4.1)

Applies gateway/profile config changes WITHOUT restarting FreeSWITCH.
Read-only probes validated live 2026-10-09; the rescan step itself is a WRITE
and is marked as such — never run it outside a change window.

## 0. Safety gates

- `show channels` reads `0 total` BEFORE and AFTER. Non-zero → STOP.
- Trunk gateway FILE changes only under `/etc/freeswitch/sip_profiles/external/trunk-*.xml`
  (deployed via `DeployTrunk`, never hand-edited on the box).
- Static tenant dialplan/directory deploys are FORBIDDEN (xml_curl is sole authority).

## 1. Pre-checks (read-only, validated 2026-10-09)

```bash
nsenter -t 1 -n python3 /root/esl_api.py "show channels" | tail -1        # want: 0 total.
nsenter -t 1 -n python3 /root/esl_api.py "sofia status"                   # profiles RUNNING
nsenter -t 1 -n python3 /root/esl_api.py "sofia status gateway"           # 0 gateways (no trunk yet)
docker exec telecom-freeswitch-1 ls /etc/freeswitch/sip_profiles/external/
```

## 2. Deploy + rescan (WRITE — change window only)

```bash
# preferred: via product code (DeployTrunk deploys the file AND rescans)
# manual fallback on the box:
docker cp ./trunk-<id>.xml telecom-freeswitch-1:/etc/freeswitch/sip_profiles/external/trunk-<id>.xml
nsenter -t 1 -n python3 /root/esl_api.py "sofia profile external rescan"
```

`rescan` (not `restart`) re-reads gateway files without dropping registrations
or active dialogs on the profile.

## 3. Verify (read-only)

```bash
nsenter -t 1 -n python3 /root/esl_api.py "sofia status gateway <gw-name>"  # want Regstate: REGISTERED (credential trunks) / NOREG (ip-auth)
nsenter -t 1 -n python3 /root/esl_api.py "show channels" | tail -1         # want: 0 total.
bash checks/I1-carrier-health.sh   # gateway-state assertion now covers REGED vs DOWN
```

## 4. Roll back

```bash
nsenter -t 1 -n python3 /root/esl_api.py "sofia profile external killgw <gw-name>"  # WRITE
docker exec telecom-freeswitch-1 rm -f /etc/freeswitch/sip_profiles/external/trunk-<id>.xml  # WRITE
nsenter -t 1 -n python3 /root/esl_api.py "sofia profile external rescan"  # WRITE
```

Record the rescan + gateway state in `fixes.log`. `restart` of the container is
NOT part of this procedure (that is E1 restart-probe territory, owner-gated).
