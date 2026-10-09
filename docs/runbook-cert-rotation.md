# Runbook: Cert Rotation (book-driven-telephony-hardening Task 4.1)

TLS posture as observed live 2026-10-09 (all probes below read-only, validated):

| Listener | Bundle | Leaf | Expiry at probe |
|---|---|---|---|
| 7443 (WSS, internal profile) | `/etc/freeswitch/tls/wss.pem` (key FIRST, then certs) | `CN = qbx.qubickle.com` (Let's Encrypt) | 82d |
| 5061 (TLS, internal profile) | `/etc/freeswitch/tls/tls.pem` | `CN = FreeSWITCH` (self-signed) | ~100y |
| external profile | NO TLS listener (`external_ssl_enable=false`, port 5081 unset) | — | — (see S6 NEEDS_CONTEXT note) |

## 0. Safety gates

- `show channels` 0 total before/after. Never touch `dtls-srtp.pem` in this flow.
- Stage the new bundle OUTSIDE the live path first; never truncate `wss.pem` in place.

## 1. Inspect current posture (read-only, validated 2026-10-09)

```bash
echo | openssl s_client -connect 88.99.250.99:7443 -servername qbx.qubickle.com 2>/dev/null \
  | openssl x509 -noout -enddate -subject          # LE leaf on 7443
docker exec telecom-freeswitch-1 sh -c \
  'grep -c "BEGIN PRIVATE KEY" /etc/freeswitch/tls/wss.pem; grep -c "BEGIN CERTIFICATE" /etc/freeswitch/tls/wss.pem'
# want: 1 key block, >=1 cert block (H4 asserts exactly this)
bash checks/H4-tls-certs.sh                        # days + bundle + handshake in one verdict
```

## 2. Rotate 7443 (WRITE — change window only, certbot or manual)

```bash
# 1. obtain renewed fullchain+privkey (certbot) on the host
# 2. assemble STAGED bundle key-first: cat privkey.pem fullchain.pem > /tmp/wss.pem.new
# 3. verify staged bundle WITHOUT touching live:
openssl x509 -noout -enddate -subject -in <(awk '/BEGIN CERTIFICATE/{p=1} p' /tmp/wss.pem.new | head -50)
# 4. swap + reload TLS (WRITE):
docker cp /tmp/wss.pem.new telecom-freeswitch-1:/etc/freeswitch/tls/wss.pem
nsenter -t 1 -n python3 /root/esl_api.py "sofia profile internal rescan"   # picks up wss.pem
# 5. re-run step 1 probes: 7443 leaf enddate moved, H4 green
```

Order matters: `wss.pem` MUST stay key-first — a cert-first bundle breaks the
TLS bind silently (H4's marker check cannot see order; eyeball `head -1`).

## 3. 5061 note

5061 serves the box-local self-signed `tls.pem` (WSS/SIP-TLS for internal legs).
Do NOT replace it with the LE cert without also updating every internal TLS
client trust store — currently out of scope; rotation here covers 7443 only.

Record old/new enddates + H4 verdict in `fixes.log`.
