source: tests/fixtures/ingest-sample.md

The external SIP profile listens on UDP/TCP port 5060; the internal profile for
extensions listens on 5080. TLS signalling is 5061, WebSocket 5067, WSS 7443.

For unknown DIDs the XML-curl resolver fails closed: UnallocatedDIDDocument
renders an explicit public-context extension whose `respond 404 Tenant DID
Unallocated` hangs the call — never silence, never 200.

FreeSWITCH configuration is container-local at /etc/freeswitch inside
telecom-freeswitch-1 and is served by the mounted entrypoint.sh on container
start; the host never holds a writable config tree.
