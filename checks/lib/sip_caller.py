#!/usr/bin/env python3
"""QBX harness minimal SIP caller: INVITE + SDP, answer 200, ACK, stream RTP, BYE.

usage: sip_caller.py <proxy_ip> <proxy_port> <target_uri> <seconds> [--user U --pass P] [--realm R]
prints only status/evidence lines; never prints credentials. exit 0 on clean BYE/200."""
import hashlib
import random
import re
import socket
import sys
import time


def md5(s):
    return hashlib.md5(s.encode()).hexdigest()


def rand_tag():
    return format(random.getrandbits(32), "08x")


class Sip(object):
    def __init__(self, proxy, port):
        self.proxy = proxy
        self.port = port
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("", 0))
        self.sock.connect((proxy, port))  # derive real source IP (no packets sent)
        self.local_ip = self.sock.getsockname()[0]
        self.local_port = self.sock.getsockname()[1]
        self.sock.settimeout(0.3)

    def send(self, msg):
        self.sock.sendto(msg.encode(), (self.proxy, self.port))

    def recv_until(self, want_re, timeout=8.0):
        deadline = time.time() + timeout
        got = []
        while time.time() < deadline:
            try:
                data, _ = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            text = data.decode(errors="replace")
            got.append(text.split("\r\n")[0])
            if re.search(want_re, text):
                return text, got
        return "", got


def digest(header, method, uri, user, pw, realm, nonce):
    m = re.search(r'realm="([^"]+)"', header)
    if m:
        realm = m.group(1)
    m = re.search(r'nonce="([^"]+)"', header)
    if m:
        nonce = m.group(1)
    qop_m = re.search(r'qop="([^"]+)"', header)
    ha1 = md5("%s:%s:%s" % (user, realm, pw))
    ha2 = md5("%s:%s" % (method, uri))
    if qop_m and "auth" in qop_m.group(1):
        nc, cnonce = "00000001", rand_tag()
        resp = md5("%s:%s:%s:%s:%s:%s" % (ha1, nonce, nc, cnonce, "auth", ha2))
        return ('Authorization: Digest username="%s", realm="%s", nonce="%s", uri="%s", '
                'response="%s", algorithm=MD5, qop=auth, nc=%s, cnonce="%s"'
                % (user, realm, nonce, uri, resp, nc, cnonce))
    resp = md5("%s:%s:%s" % (ha1, nonce, ha2))
    return ('Authorization: Digest username="%s", realm="%s", nonce="%s", uri="%s", '
            'response="%s", algorithm=MD5' % (user, realm, nonce, uri, resp))


def main():
    args = sys.argv[1:]
    proxy, port, target, seconds = args[0], int(args[1]), args[2], float(args[3])
    user = pw = None
    realm = ""
    if "--user" in args:
        user = args[args.index("--user") + 1]
        pw = args[args.index("--pass") + 1]
    if "--realm" in args:
        realm = args[args.index("--realm") + 1]
    if target.startswith("sip:"):
        uri = target
    else:
        uri = "sip:%s@%s" % (target, proxy)
    domain = uri.split("@")[-1].split(":")[0].split(";")[0]
    callid = "%d@harness" % random.getrandbits(48)
    tag, branch = rand_tag(), "z9hG4bK-h-%s" % rand_tag()
    s = Sip(proxy, port)
    rtp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rtp.bind(("", 0))
    rtp_port = rtp.getsockname()[1]

    cseq = 1
    from_h = "From: <sip:%s@%s>;tag=%s" % (user or "harness", domain, tag)
    to_h = "To: <%s>" % uri
    via_h = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (s.local_ip, s.local_port, branch)
    contact = "<sip:%s@%s:%d>" % (user or "harness", s.local_ip, s.local_port)
    sdp = ("v=0\r\no=- %d %d IN IP4 %s\r\ns=-\r\nc=IN IP4 %s\r\nt=0 0\r\n"
           "m=audio %d RTP/AVP 0 8\r\na=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\n"
           % (random.getrandbits(32), random.getrandbits(32), s.local_ip, s.local_ip, rtp_port))
    invite = ("INVITE %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d INVITE\r\n"
              "Contact: %s\r\nMax-Forwards: 70\r\nContent-Type: application/sdp\r\n"
              "Content-Length: %d\r\nUser-Agent: QBX-Harness\r\n\r\n%s"
              % (uri, via_h, from_h, to_h, callid, cseq, contact, len(sdp), sdp))

    s.send(invite)
    resp, seq = s.recv_until(r"^SIP/2.0 (200|401|407|4[0-9][0-9]|5[0-9][0-9])", 8.0)
    status = resp.split("\r\n")[0] if resp else "NO-RESPONSE"
    if not resp:
        print("invite=%s" % status)
        return 1
    if re.search(r"^SIP/2.0 (401|407)", status) and user and pw:
        auth = digest(resp, "INVITE", uri, user, pw, realm, "")
        cseq += 1
        branch = "z9hG4bK-h-%s" % rand_tag()
        via_h = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (s.local_ip, s.local_port, branch)
        invite2 = ("INVITE %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d INVITE\r\n"
                   "%s\r\n%s\r\nMax-Forwards: 70\r\nContent-Type: application/sdp\r\n"
                   "Content-Length: %d\r\n\r\n%s"
                   % (uri, via_h, from_h, to_h, callid, cseq, auth, contact, len(sdp), sdp))
        s.send(invite2)
        resp, seq = s.recv_until(r"^SIP/2.0 (200|4[0-9][0-9]|5[0-9][0-9])", 8.0)
        status = resp.split("\r\n")[0] if resp else "NO-RESPONSE"
    print("invite=%s" % status.split("\r\n")[0])
    if not status.startswith("SIP/2.0 200"):
        print("seen=%s" % " | ".join(seq[:6]))
        return 1

    m = re.search(r"c=IN IP4 (\S+)", resp)
    media_ip = m.group(1) if m else proxy
    m = re.search(r"m=audio (\d+)", resp)
    media_port = int(m.group(1)) if m else 0
    ack = ("ACK %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d ACK\r\n"
           "Max-Forwards: 70\r\nContent-Length: 0\r\n\r\n"
           % (uri, via_h, from_h, to_h, callid, cseq))
    s.send(ack)
    print("answered media=%s:%d" % (media_ip, media_port))

    # stream PCMU silence (proper RTP headers) toward FreeSWITCH for the requested duration
    import struct
    seq, ts = 0, 0
    ssrc = random.getrandbits(32)
    payload = b"\xff" * 160
    deadline = time.time() + seconds
    sent = 0
    while time.time() < deadline and media_port:
        hdr = struct.pack("!BBHII", 0x80, 0, seq & 0xFFFF, ts & 0xFFFFFFFF, ssrc)
        rtp.sendto(hdr + payload, (media_ip, media_port))
        seq += 1
        ts += 160
        sent += 1
        time.sleep(0.02)
    print("rtp_sent=%d" % sent)

    cseq += 1
    branch = "z9hG4bK-h-%s" % rand_tag()
    via_h = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (s.local_ip, s.local_port, branch)
    bye = ("BYE %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d BYE\r\n"
           "Max-Forwards: 70\r\nContent-Length: 0\r\n\r\n"
           % (uri, via_h, from_h, to_h, callid, cseq))
    s.send(bye)
    resp2, _ = s.recv_until(r"^SIP/2.0 \d\d\d", 5.0)
    print("bye=%s" % (resp2.split("\r\n")[0] if resp2 else "NO-RESPONSE"))
    rtp.close()
    s.sock.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
