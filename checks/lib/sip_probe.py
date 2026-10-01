#!/usr/bin/env python3
"""QBX harness SIP probe: OPTIONS or INVITE (with SDP + Contact).
usage: sip_probe.py <host> <port> OPTIONS|INVITE <target>
prints status=/ua=/reason= lines only. exit 0 if any response, 1 on timeout."""
import random, re, socket, sys, time

def rand_tag(): return format(random.getrandbits(32), "08x")

def main():
    host, port, mode, target = sys.argv[1], int(sys.argv[2]), sys.argv[3].upper(), sys.argv[4]
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("", 0)); s.connect((host, port))          # derive real source IP
    lip, lport = s.getsockname(); s.settimeout(0.4)
    tag, branch = rand_tag(), rand_tag()
    uri = "sip:%s@%s" % (target, host)
    if mode == "OPTIONS":
        msg = ("OPTIONS %s SIP/2.0\r\nVia: SIP/2.0/UDP %s:%d;rport;branch=z9hG4bK-%s\r\n"
               "From: <sip:probe@%s>;tag=%s\r\nTo: <%s>\r\nCall-ID: %s@probe\r\n"
               "CSeq: 1 OPTIONS\r\nMax-Forwards: 70\r\nUser-Agent: QBX-Harness\r\n"
               "Content-Length: 0\r\n\r\n" % (uri, lip, lport, branch, host, tag, uri,
                                              random.getrandbits(48)))
    elif mode == "INVITE":
        sdp = ("v=0\r\no=- 1 1 IN IP4 %s\r\ns=-\r\nc=IN IP4 %s\r\nt=0 0\r\n"
               "m=audio 20000 RTP/AVP 0\r\na=rtpmap:0 PCMU/8000\r\n" % (lip, lip))
        msg = ("INVITE %s SIP/2.0\r\nVia: SIP/2.0/UDP %s:%d;rport;branch=z9hG4bK-%s\r\n"
               "From: <sip:2025550123@198.211.99.232>;tag=%s\r\nTo: <%s>\r\n"
               "Contact: <sip:2025550123@198.211.99.232>\r\nCall-ID: %s@probe\r\n"
               "CSeq: 1 INVITE\r\nMax-Forwards: 70\r\nUser-Agent: QBX-Harness\r\n"
               "Content-Type: application/sdp\r\nContent-Length: %d\r\n\r\n%s"
               % (uri, lip, lport, branch, tag, uri, random.getrandbits(48), len(sdp), sdp))
    else:
        print("usage-error: mode must be OPTIONS|INVITE"); return 2
    s.send(msg.encode())
    deadline, last, any_resp = time.time() + 8, "", False
    while time.time() < deadline:
        try:
            data, _ = s.recvfrom(65535)
        except (socket.timeout, OSError):   # closed port -> ICMP refused -> OSError, not a traceback
            continue
        text = data.decode(errors="replace"); any_resp = True
        first = text.split("\r\n")[0]
        ua = next((l.split(":", 1)[1].strip() for l in text.split("\r\n")
                   if l.lower().startswith("user-agent:")), "-")
        last = first
        print("status=%s" % first); print("ua=%s" % ua)
        if not first.startswith("SIP/2.0 100"):       # skip provisional, keep final
            break
    s.close()
    if not any_resp:
        print("status=NO-RESPONSE"); print("ua=-"); return 1
    print("reason=%s" % last); return 0

sys.exit(main())
