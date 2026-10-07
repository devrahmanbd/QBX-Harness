# tests/12-dtmf.test.sh — Task 2 probe: sip_caller RFC2833 DTMF send (offer te/101, fail-closed verify, digit round-trip)
#!/usr/bin/env bash
set -uo pipefail
H=/root/qbx-harness
TD=$(mktemp -d)
trap 'rm -rf "$TD"' EXIT

# ---- hermetic SIP peer fixture: answers one INVITE (SDP with or without telephone-event/101),
# ---- records the offer, drains RTP (audio + PT101 events) into a stats JSON ----
cat >"$TD/mock_sip.py" <<'PYEOF'
#!/usr/bin/env python3
import json, random, re, select, socket, struct, sys, time

te = sys.argv[1] == "1"
stats_path, port_file = sys.argv[2], sys.argv[3]
sip = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sip.bind(("127.0.0.1", 0))
rtp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); rtp.bind(("127.0.0.1", 0))
sip_port, rtp_port = sip.getsockname()[1], rtp.getsockname()[1]
with open(port_file, "w") as fh:
    fh.write(str(sip_port))

stats = {"offer_mline": "", "offer_te": False, "ack": False, "bye": False,
         "audio_n": 0, "te": []}

def eat(pkt):
    if len(pkt) < 16:
        return
    pt = pkt[1] & 0x7f
    if pt == 101:
        stats["te"].append({"pt": pt, "event": pkt[12], "end": bool(pkt[13] & 0x80),
                            "vol": pkt[13] & 0x3f,
                            "dur": struct.unpack("!H", pkt[14:16])[0],
                            "seq": struct.unpack("!H", pkt[2:4])[0],
                            "ts": struct.unpack("!I", pkt[4:8])[0],
                            "ssrc": struct.unpack("!I", pkt[8:12])[0]})
    else:
        stats["audio_n"] += 1

def hdrs(msg):
    h = {}
    for line in msg.split("\r\n\r\n", 1)[0].split("\r\n")[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            h.setdefault(k.strip().lower(), []).append(v.strip())
    return h

def resp_line(req_head, code, reason, to_tag=None):
    h = hdrs(req_head)
    names = {"via": "Via", "from": "From", "to": "To", "call-id": "Call-ID", "cseq": "CSeq"}
    out = ["SIP/2.0 %d %s" % (code, reason)]
    for key in ("via", "from", "to", "call-id", "cseq"):
        for v in h.get(key, []):
            if key == "to" and to_tag:
                v = v + ";tag=" + to_tag
            out.append("%s: %s" % (names[key], v))
    return out

deadline = time.time() + 25
while time.time() < deadline:
    r, _, _ = select.select([sip, rtp], [], [], 0.25)
    if rtp in r:
        eat(rtp.recvfrom(65535)[0])
        continue
    if sip not in r:
        continue
    data, addr = sip.recvfrom(65535)
    msg = data.decode(errors="replace")
    first = msg.split("\r\n")[0]
    if first.startswith("INVITE "):
        h = hdrs(msg)
        sdp = msg.split("\r\n\r\n", 1)[-1] if "\r\n\r\n" in msg else ""
        m = re.search(r"^m=audio[^\r\n]*", sdp, re.M)
        stats["offer_mline"] = m.group(0) if m else ""
        stats["offer_te"] = bool(re.search(r"^a=rtpmap:101[ \t]+telephone-event", sdp, re.M | re.I))
        if te:
            asdp = ("v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
                    "m=audio %d RTP/AVP 0 101\r\na=rtpmap:0 PCMU/8000\r\n"
                    "a=rtpmap:101 telephone-event/8000\r\na=fmtp:101 0-15\r\n" % rtp_port)
        else:
            asdp = ("v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\n"
                    "m=audio %d RTP/AVP 0 8\r\na=rtpmap:0 PCMU/8000\r\n"
                    "a=rtpmap:8 PCMA/8000\r\n" % rtp_port)
        out = resp_line(msg, 200, "OK", to_tag="mock-%x" % random.getrandbits(16))
        out.append("Contact: <sip:mock@127.0.0.1:%d>" % sip_port)
        out.append("Content-Type: application/sdp")
        out.append("Content-Length: %d" % len(asdp))
        sip.sendto(("\r\n".join(out) + "\r\n\r\n" + asdp).encode(), addr)
    elif first.startswith("ACK "):
        stats["ack"] = True
    elif first.startswith("BYE "):
        out = resp_line(msg, 200, "OK")
        out.append("Content-Length: 0")
        sip.sendto(("\r\n".join(out) + "\r\n\r\n").encode(), addr)
        stats["bye"] = True
        end = time.time() + 0.4
        while time.time() < end:
            r2, _, _ = select.select([rtp], [], [], 0.1)
            if rtp in r2:
                eat(rtp.recvfrom(65535)[0])
        break
with open(stats_path, "w") as fh:
    json.dump(stats, fh)
PYEOF

# helper: start mock, echo pid (fds detached from the $() pipe so it never blocks)
mock_up() {  # $1=tag $2=te 0|1
  python3 "$TD/mock_sip.py" "$2" "$TD/$1.stats.json" "$TD/$1.port" >"$TD/$1.log" 2>&1 &
  echo $!
}
mock_wait() {  # $1=tag
  for _ in $(seq 1 50); do [ -s "$TD/$1.port" ] && return 0; sleep 0.1; done
  return 1
}
mock_stats() {  # $1=tag $2=pid — wait for stats JSON, kill straggler
  for _ in $(seq 1 60); do [ -f "$TD/$1.stats.json" ] && return 0; sleep 0.5; done
  kill "$2" 2>/dev/null; wait "$2" 2>/dev/null
  [ -f "$TD/$1.stats.json" ]
}

# ---- A) fail-closed: peer answers WITHOUT telephone-event/101 -> exit 1, UNAVAILABLE, zero media ----
am=$(mock_up a 0)
mock_wait a || { echo "A: mock never ready"; exit 1; }
python3 "$H/checks/lib/sip_caller.py" 127.0.0.1 "$(cat "$TD/a.port")" qbx-test-mock 2 \
  --dtmf "5" >"$TD/a.out" 2>&1
rc=$?
mock_stats a "$am" || { echo "A: mock produced no stats"; exit 1; }
[ "$rc" -eq 1 ] || { echo "A: want exit 1 (fail closed), got $rc: $(tr '\n' '|' <"$TD/a.out")"; exit 1; }
grep -q '^dtmf=UNAVAILABLE' "$TD/a.out" || { echo "A: missing dtmf=UNAVAILABLE: $(tr '\n' '|' <"$TD/a.out")"; exit 1; }
grep -q '^dtmf_sent=0$' "$TD/a.out" || { echo "A: missing dtmf_sent=0: $(tr '\n' '|' <"$TD/a.out")"; exit 1; }
grep -q '^bye=SIP/2.0 200' "$TD/a.out" || { echo "A: no clean BYE on fail path: $(tr '\n' '|' <"$TD/a.out")"; exit 1; }
jq -e '.offer_te == true and .bye == true and (.te|length) == 0 and .audio_n == 0' \
  "$TD/a.stats.json" >/dev/null \
  || { echo "A: want offered-te + BYE + zero RTP; got: $(cat "$TD/a.stats.json")"; exit 1; }

# ---- B) sender packet shape: peer answers WITH telephone-event/101 -> RFC2833 events land, well-formed ----
bm=$(mock_up b 1)
mock_wait b || { echo "B: mock never ready"; exit 1; }
python3 "$H/checks/lib/sip_caller.py" 127.0.0.1 "$(cat "$TD/b.port")" qbx-test-mock 5 \
  --dtmf "5#" >"$TD/b.out" 2>&1
rc=$?
mock_stats b "$bm" || { echo "B: mock produced no stats"; exit 1; }
[ "$rc" -eq 0 ] || { echo "B: want exit 0, got $rc: $(tr '\n' '|' <"$TD/b.out")"; exit 1; }
grep -q '^dtmf=ok pt=101$' "$TD/b.out" || { echo "B: missing dtmf=ok: $(tr '\n' '|' <"$TD/b.out")"; exit 1; }
grep -q '^dtmf_sent=2$' "$TD/b.out" || { echo "B: missing dtmf_sent=2: $(tr '\n' '|' <"$TD/b.out")"; exit 1; }
grep -q '^invite=SIP/2.0 200' "$TD/b.out" && grep -q '^bye=SIP/2.0 200' "$TD/b.out" \
  || { echo "B: call did not complete: $(tr '\n' '|' <"$TD/b.out")"; exit 1; }
python3 - "$TD/b.stats.json" <<'PYEOF'
import json, sys
s = json.load(open(sys.argv[1]))
assert s["offer_te"], "offer lacks telephone-event/101: %s" % s["offer_mline"]
assert "RTP/AVP 0 8 101" in s["offer_mline"], "bad offer m-line: %s" % s["offer_mline"]
assert s["ack"] and s["bye"], "no ACK/BYE: %s" % s
assert s["audio_n"] >= 20, "audio stream too short: %d" % s["audio_n"]
te = s["te"]
assert len(te) == 30, "want 30 event packets (2 digits x 15), got %d" % len(te)
assert all(p["pt"] == 101 for p in te), "non-101 event pt"
groups = [(5, te[:15]), (11, te[15:])]
for code, g in groups:
    assert [p["event"] for p in g] == [code] * 15, "event codes: %s" % [p["event"] for p in g]
    assert len({p["ts"] for p in g}) == 1, "event timestamp must freeze within event"
    seqs = [p["seq"] for p in g]
    assert all((b - a) % 65536 == 1 for a, b in zip(seqs, seqs[1:])), "seq not +1: %s" % seqs
    assert [p["dur"] for p in g[:12]] == [160 * k for k in range(1, 13)], "duration ramp: %s" % [p["dur"] for p in g[:12]]
    assert [p["dur"] for p in g[12:]] == [2000] * 3, "final duration must be 2000: %s" % [p["dur"] for p in g[12:]]
    assert [p["end"] for p in g] == [False] * 12 + [True] * 3, "E-bit on last 3 packets"
    assert all(p["vol"] <= 63 for p in g), "volume out of range"
assert len({p["ssrc"] for p in te}) == 1, "events must share the audio SSRC"
print("packet-shape ok")
PYEOF
[ $? -eq 0 ] || { echo "B: packet shape invalid"; exit 1; }

# ---- C) byte-compat when DTMF not requested: legacy output shape + legacy offer + no events ----
dm=$(mock_up d 1)
mock_wait d || { echo "C: mock never ready"; exit 1; }
python3 "$H/checks/lib/sip_caller.py" 127.0.0.1 "$(cat "$TD/d.port")" qbx-test-mock 3 \
  >"$TD/d.out" 2>&1
rc=$?
mock_stats d "$dm" || { echo "C: mock produced no stats"; exit 1; }
[ "$rc" -eq 0 ] || { echo "C: want exit 0, got $rc: $(tr '\n' '|' <"$TD/d.out")"; exit 1; }
n=$(wc -l <"$TD/d.out")
[ "$n" -eq 4 ] || { echo "C: legacy output must stay 4 lines, got $n: $(tr '\n' '|' <"$TD/d.out")"; exit 1; }
grep -q '^invite=SIP/2.0 200' "$TD/d.out" && grep -q '^answered media=' "$TD/d.out" \
  && grep -q '^rtp_sent=[0-9]' "$TD/d.out" && grep -q '^bye=SIP/2.0 200' "$TD/d.out" \
  || { echo "C: legacy lines changed: $(tr '\n' '|' <"$TD/d.out")"; exit 1; }
! grep -qi 'dtmf' "$TD/d.out" || { echo "C: dtmf output leaked into legacy path: $(tr '\n' '|' <"$TD/d.out")"; exit 1; }
jq -e '.offer_te == false and (.offer_mline | test("^m=audio [0-9]+ RTP/AVP 0 8$"))
       and (.te|length) == 0 and .audio_n >= 20 and .ack == true and .bye == true' \
  "$TD/d.stats.json" >/dev/null \
  || { echo "C: legacy offer/RTP changed: $(cat "$TD/d.stats.json")"; exit 1; }

# ---- D) live round-trip: FreeSWITCH echo leg accepts te/101, decodes digits (RECV DTMF in FS log) ----
LOG=/root/QBX/logs/freeswitch/freeswitch.log
ext_secret=$(nsenter -t 1 -n psql "${DATABASE_URL:-$(grep -h '^DATABASE_URL=' /root/QBX/.env | cut -d= -f2-)}" \
  -tAX -c "SELECT secret FROM extensions WHERE extension_number='4000'" 2>/dev/null)
[ -n "$ext_secret" ] || { echo "D: ext 4000 secret lookup empty"; exit 1; }
t0=$(date +%s)
nsenter -t 1 -n python3 "$H/checks/lib/sip_caller.py" 88.99.250.99 5080 qbx-test-echo 9 \
  --user 4000 --pass "$ext_secret" --dtmf "5#" --dtmf-delay 1.5 >"$TD/d2.out" 2>&1 &
caller=$!
unset ext_secret
uuid=""
for _ in $(seq 1 12); do
  ch=$(nsenter -t 1 -n python3 /root/esl_api.py "show channels" 2>/dev/null)
  uuid=$(awk -F, -v t="$t0" '/^[0-9a-f]{8}-[0-9a-f-]{27}/ && /,echo,/ && $4+0 >= t-15 {if ($4+0 > max) {max=$4+0; id=$1}} END {print id}' <<<"$ch")
  [ -n "$uuid" ] && break
  sleep 1
done
if [ -z "$uuid" ]; then kill "$caller" 2>/dev/null; wait "$caller" 2>/dev/null
  echo "D: echo leg never appeared: $(tr '\n' '|' <"$TD/d2.out")"; exit 1; fi
sleep 4   # digits finish at ~1.5s + 2 events (~3s total)
nsenter -t 1 -n python3 /root/esl_api.py "uuid_set_media_stats $uuid" >/dev/null 2>&1
nsenter -t 1 -n python3 /root/esl_api.py "uuid_dump $uuid json" >"$TD/d2.dump.json" 2>/dev/null
wait "$caller"; crc=$?
[ "$crc" -eq 0 ] || { echo "D: caller rc=$crc: $(tr '\n' '|' <"$TD/d2.out")"; exit 1; }
grep -q '^dtmf=ok pt=101$' "$TD/d2.out" || { echo "D: missing dtmf=ok: $(tr '\n' '|' <"$TD/d2.out")"; exit 1; }
grep -q '^dtmf_sent=2$' "$TD/d2.out" || { echo "D: missing dtmf_sent=2: $(tr '\n' '|' <"$TD/d2.out")"; exit 1; }
grep -q '^invite=SIP/2.0 200' "$TD/d2.out" && grep -q '^bye=SIP/2.0 200' "$TD/d2.out" \
  || { echo "D: call incomplete: $(tr '\n' '|' <"$TD/d2.out")"; exit 1; }
dt=$(jq -r '.variable_dtmf_type // ""' "$TD/d2.dump.json" 2>/dev/null)
[ "$dt" = "rfc2833" ] || { echo "D: variable_dtmf_type='$dt' want rfc2833"; exit 1; }
pk=$(jq -r '.variable_rtp_audio_in_dtmf_packet_count // 0' "$TD/d2.dump.json" 2>/dev/null)
[ "${pk:-0}" -ge 15 ] || { echo "D: inbound dtmf packet count=$pk want >=15"; exit 1; }
grep -a -q "^$uuid .*RECV DTMF 5:2[0-9][0-9][0-9]" "$LOG" \
  || { echo "D: FS log lacks RECV DTMF 5 for $uuid"; exit 1; }
grep -a -q "^$uuid .*RECV DTMF #:2[0-9][0-9][0-9]" "$LOG" \
  || { echo "D: FS log lacks RECV DTMF # for $uuid"; exit 1; }
sleep 2
left=$(nsenter -t 1 -n python3 /root/esl_api.py "show channels like $uuid" 2>/dev/null | grep -cE '^[0-9a-f]{8}-[0-9a-f-]{27}')
[ "${left:-0}" -eq 0 ] || { echo "D: channel not hung up after BYE: $uuid"; exit 1; }
echo ok
