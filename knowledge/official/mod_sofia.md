source: context7//signalwire/freeswitch-docs — mod_sofia profile/UA parameters

# mod_sofia — SIP profile and user-agent parameters (official docs)

Retrieved via context7 MCP `query-docs` from the official FreeSWITCH docs
(/signalwire/freeswitch-docs, mirroring docs at
github.com/signalwire/freeswitch-docs/docs/users-endpoints/sip-profiles-sofia.mdx).

## Internal SIP profile configuration

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/users-endpoints/sip-profiles-sofia.mdx

The internal profile lives at `conf/sip_profiles/internal.xml` and defines
settings for SIP ports, authentication, presence, and WebRTC support:

```xml
<profile name="internal">
  <aliases></aliases>
  <gateways></gateways>
  <domains>
    <domain name="all" alias="true" parse="false"/>
  </domains>
  <settings>
    <param name="context" value="public"/>
    <param name="sip-port" value="$${internal_sip_port}"/>
    <param name="sip-ip" value="$${local_ip_v4}"/>
    <param name="rtp-ip" value="$${local_ip_v4}"/>
    <param name="ext-rtp-ip" value="$${external_rtp_ip}"/>
    <param name="ext-sip-ip" value="$${external_sip_ip}"/>
    <param name="dialplan" value="XML"/>
    <param name="auth-calls" value="$${internal_auth_calls}"/>
    <param name="inbound-codec-prefs" value="$${global_codec_prefs}"/>
    <param name="outbound-codec-prefs" value="$${global_codec_prefs}"/>
    <param name="inbound-codec-negotiation" value="generous"/>
    <param name="inbound-late-negotiation" value="true"/>
    <param name="manage-presence" value="true"/>
    <param name="apply-inbound-acl" value="domains"/>
    <param name="apply-nat-acl" value="nat.auto"/>
    <param name="nonce-ttl" value="60"/>
    <param name="auth-all-packets" value="false"/>
    <param name="auth-subscriptions" value="true"/>
    <param name="challenge-realm" value="auto_from"/>
    <param name="rtp-timeout-sec" value="300"/>
    <param name="rtp-hold-timeout-sec" value="1800"/>
    <param name="tls" value="$${internal_ssl_enable}"/>
    <param name="tls-sip-port" value="$${internal_tls_port}"/>
    <param name="ws-binding" value=":5066"/>
    <param name="wss-binding" value=":7443"/>
    <param name="force-register-domain" value="$${domain}"/>
  </settings>
</profile>
```

## External SIP profile configuration

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/users-endpoints/sip-profiles-sofia.mdx

`conf/sip_profiles/external.xml` handles outbound traffic and gateway
definitions:

```xml
<profile name="external">
  <gateways>
    <X-PRE-PROCESS cmd="include" data="external/*.xml"/>
  </gateways>
  <domains>
    <domain name="all" alias="false" parse="true"/>
  </domains>
  <settings>
    <param name="context" value="public"/>
    <param name="sip-port" value="$${external_sip_port}"/>
    <param name="sip-ip" value="$${local_ip_v4}"/>
    <param name="rtp-ip" value="$${local_ip_v4}"/>
    <param name="ext-rtp-ip" value="$${external_rtp_ip}"/>
    <param name="ext-sip-ip" value="$${external_sip_ip}"/>
    <param name="dialplan" value="XML"/>
    <param name="auth-calls" value="false"/>
    <param name="nonce-ttl" value="60"/>
    <param name="tls" value="$${external_ssl_enable}"/>
    <param name="tls-sip-port" value="$${external_tls_port}"/>
  </settings>
</profile>
```

## Minimal Sofia profile (NAT, authentication, codecs)

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/users-endpoints/sip-profiles-sofia.mdx

```xml
<profile name="myprofile">
  <settings>
    <param name="sip-ip"  value="192.0.2.10"/>
    <param name="rtp-ip"  value="192.0.2.10"/>
    <param name="sip-port" value="5060"/>
    <param name="ext-sip-ip"  value="203.0.113.1"/>
    <param name="ext-rtp-ip"  value="203.0.113.1"/>
    <param name="context"  value="default"/>
    <param name="dialplan" value="XML"/>
    <param name="auth-calls"    value="true"/>
    <param name="nonce-ttl"     value="60"/>
    <param name="challenge-realm" value="auto_from"/>
    <param name="apply-nat-acl"      value="nat.auto"/>
    <param name="apply-inbound-acl"  value="domains"/>
    <param name="inbound-codec-prefs"       value="OPUS,G722,PCMU,PCMA"/>
    <param name="outbound-codec-prefs"      value="OPUS,G722,PCMU,PCMA"/>
    <param name="inbound-codec-negotiation" value="generous"/>
    <param name="rtp-timer-name" value="soft"/>
    <param name="dtmf-type" value="rfc2833"/>
    <param name="hold-music" value="local_stream://moh"/>
  </settings>
</profile>
```

## NAT / RTP parameters (RTP cannot flow root cause)

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/troubleshooting/audio-problems.mdx

| Parameter | Role | Vanilla default |
| --- | --- | --- |
| `rtp-ip` | Local IP address RTP sockets bind to | `$${local_ip_v4}` |
| `sip-ip` | Local IP address the SIP transport binds to | `$${local_ip_v4}` |
| `ext-rtp-ip` | Public IP advertised in the SDP `c=` line for media | `$${external_rtp_ip}` (external profile) |
| `ext-sip-ip` | Public IP advertised in SIP `Contact`/`Via` | `$${external_sip_ip}` (external profile) |
| `apply-nat-acl` | ACL that marks a remote contact as being behind NAT | `nat.auto` (internal profile) |
| `local-network-acl` | ACL defining which networks are "local" (no NAT treatment) | `localnet.auto` |

`ext-rtp-ip` accepts a literal IP address, `auto`, `auto-nat`,
`stun:<server>`, or `host:<name>`.

## UA / caller-ID handling

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/recipes/recipe-box-to-box.mdx

By default a gateway uses its own `username` (or `from-user`) as the `From`
user. To pass the original caller's number across the trunk, set
`effective_caller_id_number` before the bridge, or set the gateway parameter
`caller-id-in-from` to `true`, which uses the inbound caller ID as the `From`
user on calls bridged out through that gateway.

## Inbound fields set by mod_sofia (UA observability)

Source: https://github.com/signalwire/freeswitch-docs/blob/main/docs/reference/channel-variables.mdx

| Variable | Purpose |
|---|---|
| `sip_from_user` | User part of the SIP From URI of the incoming request. |
| `sip_to_user` | User part of the SIP To URI of the incoming request. |
| `sip_contact_user` | User part of the Contact URI from the incoming request. |
| `sip_call_id` | SIP Call-ID header value of the dialog. |
| `sip_user_agent` | The User-Agent or Server header string from the remote SIP party. |
| `sip_network_ip` | IP of the interface the SIP message arrived on (set by `mod_sofia`). |
| `sip_received_ip` | Source IP the request came from; may differ from `sip_network_ip` under NAT. |
| `sip_via_protocol` | Transport protocol of the topmost Via header (e.g. `UDP`, `TCP`, `TLS`). |
| `sip_cid_type` | Caller-ID presentation type: `rpid` (Remote-Party-ID) or `pid` (P-Asserted-Identity / P-Preferred-Identity), set by `mod_sofia` in `sofia.c`. |
