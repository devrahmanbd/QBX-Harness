#!/usr/bin/env python3
"""REFER blind-transfer probe: INVITE qbx-test-echo, in-dialog REFER to qbx-test-echo.
usage: refer_probe.py <proxy> <port> <user> <pass> <realm> <seconds>
prints status lines only (never credentials). exit 0 iff REFER got 2xx.
ph2 task 4(ii): transfer between own test legs only; BYE cleanup always attempted."""
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


def digest(header, method, uri, user, pw, realm, proxy=False):
    # RFC 3261 s22: 407 (Proxy-Authenticate) -> Proxy-Authorization,
    # 401 (WWW-Authenticate) -> Authorization. Sofia re-issues 407 when the
    # wrong header answers a proxy challenge (double-407).
    scheme = "Proxy-Authorization" if proxy else "Authorization"
    m = re.search(r'realm="([^"]+)"', header)
    if m:
        realm = m.group(1)
    m = re.search(r'nonce="([^"]+)"', header)
    nonce = m.group(1) if m else ""
    qop_m = re.search(r'qop="([^"]+)"', header)
    ha1 = md5("%s:%s:%s" % (user, realm, pw))
    ha2 = md5("%s:%s" % (method, uri))
    if qop_m and "auth" in qop_m.group(1):
        nc, cnonce = "00000001", rand_tag()
        resp = md5("%s:%s:%s:%s:%s:%s" % (ha1, nonce, nc, cnonce, "auth", ha2))
        return ('%s: Digest username="%s", realm="%s", nonce="%s", uri="%s", '
                'response="%s", algorithm=MD5, qop=auth, nc=%s, cnonce="%s"'
                % (scheme, user, realm, nonce, uri, resp, nc, cnonce))
    resp = md5("%s:%s:%s" % (ha1, nonce, ha2))
    return ('%s: Digest username="%s", realm="%s", nonce="%s", uri="%s", '
            'response="%s", algorithm=MD5' % (scheme, user, realm, nonce, uri, resp))


def main():
    proxy, port = sys.argv[1], int(sys.argv[2])
    user, pw, realm = sys.argv[3], sys.argv[4], sys.argv[5]
    hold = float(sys.argv[6]) if len(sys.argv) > 6 else 12.0
    target = "qbx-test-echo"
    uri = "sip:%s@%s" % (target, realm)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("", 0))
    sock.connect((proxy, port))
    lip, lport = sock.getsockname()[0], sock.getsockname()[1]
    sock.settimeout(0.3)

    def xfer(msgs):
        for m in msgs:
            sock.sendto(m.encode(), (proxy, port))

    def recv_until(want_re, timeout):
        deadline = time.time() + timeout
        got = []
        while time.time() < deadline:
            try:
                data, _ = sock.recvfrom(65535)
            except socket.timeout:
                continue
            text = data.decode(errors="replace")
            got.append(text.split("\r\n")[0])
            if re.search(want_re, text, re.M):
                return text, got
        return "", got

    def recv_match(branch, cseq, method, timeout):
        # Strict transaction match (Via branch + CSeq): FS retransmits the
        # INVITE 407 for ~32s and first-final-wins receives ate those strays
        # as live answers. Provisionals skipped, strays ignored.
        deadline = time.time() + timeout
        while time.time() < deadline:
            resp, _ = recv_until(r"^SIP/2.0 \d\d\d", 1.0)
            if not resp or resp.startswith("SIP/2.0 1"):
                continue
            vb = re.search(r"branch=([^;\s]+)", resp)
            cs = re.search(r"^CSeq:\s*(\S+.*)$", resp, re.M)
            if vb and cs and vb.group(1) == branch and cs.group(1).strip() == "%d %s" % (cseq, method):
                return resp
        return ""

    callid = "%d@referprobe" % random.getrandbits(48)
    tag = rand_tag()
    branch = "z9hG4bK-h-%s" % rand_tag()
    via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (lip, lport, branch)
    frm = "From: <sip:%s@%s>;tag=%s" % (user, realm, tag)
    to = "To: <%s>" % uri
    contact = "<sip:%s@%s:%d>" % (user, lip, lport)
    sdp = ("v=0\r\no=- %d %d IN IP4 %s\r\ns=-\r\nc=IN IP4 %s\r\nt=0 0\r\n"
           "m=audio %d RTP/AVP 0 8\r\na=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\n"
           % (random.getrandbits(32), random.getrandbits(32), lip, lip, 15000 + random.getrandbits(12)))
    cseq = 1
    inv = ("INVITE %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d INVITE\r\n"
           "Contact: %s\r\nMax-Forwards: 70\r\nContent-Type: application/sdp\r\n"
           "Content-Length: %d\r\nUser-Agent: QBX-ReferProbe\r\n\r\n%s"
           % (uri, via, frm, to, callid, cseq, contact, len(sdp), sdp))
    xfer([inv])
    resp = recv_match(branch, cseq, "INVITE", 8.0)
    status = resp.split("\r\n")[0] if resp else "NO-RESPONSE"
    if not resp:
        print("invite=%s" % status)
        return 1
    if re.search(r"^SIP/2.0 (401|407)", status):
        auth = digest(resp, "INVITE", uri, user, pw, realm, proxy=status.startswith("SIP/2.0 407"))
        cseq += 1
        branch = "z9hG4bK-h-%s" % rand_tag()
        via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (lip, lport, branch)
        inv2 = ("INVITE %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d INVITE\r\n"
                "%s\r\nContact: %s\r\nMax-Forwards: 70\r\nContent-Type: application/sdp\r\n"
                "Content-Length: %d\r\n\r\n%s"
                % (uri, via, frm, to, callid, cseq, auth, contact, len(sdp), sdp))
        xfer([inv2])
        resp = recv_match(branch, cseq, "INVITE", 8.0)
        status = resp.split("\r\n")[0] if resp else "NO-RESPONSE"
    print("invite=%s" % status.split("\r\n")[0])
    if not status.startswith("SIP/2.0 200"):
        return 1
    to_tag = ""
    mt = re.search(r"^To:.*tag=([^\s;>]+)", resp, re.M)
    if mt:
        to_tag = mt.group(1)
    mc = re.search(r"^Contact:\s*<?([^>\s]+)", resp, re.M)
    remote = mc.group(1) if mc else uri
    to_full = "To: <%s>;tag=%s" % (uri, to_tag) if to_tag else to
    ack = ("ACK %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d ACK\r\n"
           "Max-Forwards: 70\r\nContent-Length: 0\r\n\r\n"
           % (remote, via, frm, to_full, callid, cseq))
    xfer([ack])
    print("answered to_tag=%s" % (to_tag[:12] if to_tag else "none"))
    time.sleep(1.0)
    # in-dialog REFER (blind): ask FS to connect this dialog to a fresh echo leg
    cseq += 1
    branch = "z9hG4bK-h-%s" % rand_tag()
    via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (lip, lport, branch)
    refer_to = "<sip:%s@%s>" % (target, realm)
    refer = ("REFER %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d REFER\r\n"
             "Contact: %s\r\nMax-Forwards: 70\r\nRefer-To: %s\r\n"
             "Referred-By: <sip:%s@%s>\r\nContent-Length: 0\r\n\r\n"
             % (remote, via, frm, to_full, callid, cseq, contact, refer_to, user, realm))
    xfer([refer])
    rresp = recv_match(branch, cseq, "REFER", 8.0)
    rstatus = rresp.split("\r\n")[0] if rresp else "NO-RESPONSE"
    print("refer=%s" % rstatus)
    if re.match(r"^SIP/2.0 (401|407)", rstatus):
        # In-dialog REFER challenged: answer once with the fresh challenge.
        rauth = digest(rresp, "REFER", remote, user, pw, realm,
                       proxy=rstatus.startswith("SIP/2.0 407"))
        cseq += 1
        branch = "z9hG4bK-h-%s" % rand_tag()
        via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (lip, lport, branch)
        refer2 = ("REFER %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d REFER\r\n"
                  "%s\r\nContact: %s\r\nMax-Forwards: 70\r\nRefer-To: %s\r\n"
                  "Referred-By: <sip:%s@%s>\r\nContent-Length: 0\r\n\r\n"
                  % (remote, via, frm, to_full, callid, cseq, rauth, contact, refer_to, user, realm))
        xfer([refer2])
        rresp = recv_match(branch, cseq, "REFER", 8.0)
        rstatus = rresp.split("\r\n")[0] if rresp else "NO-RESPONSE"
        print("refer_auth=%s" % rstatus)
    notified = ""
    if rstatus.startswith("SIP/2.0 2"):
        # collect NOTIFYs + possible BYE for the hold window
        deadline = time.time() + hold
        while time.time() < deadline:
            try:
                data, _ = sock.recvfrom(65535)
            except socket.timeout:
                continue
            text = data.decode(errors="replace")
            first = text.split("\r\n")[0]
            if first.startswith("NOTIFY"):
                m = re.search(r"SIP/2.0 (\d\d\d)", text)
                body_state = m.group(1) if m else "?"
                notified = (notified + "+" + body_state) if notified else body_state
                # 200 the NOTIFY (swap To/From tags)
                mt2 = re.search(r"^To:.*tag=([^\s;>]+)", text, re.M)
                mf = re.search(r"^From:.*tag=([^\s;>]+)", text, re.M)
                nto = "To: <sip:%s@%s:%d>%s" % (user, lip, lport, (";tag=" + mf.group(1)) if mf else "")
                nfrom = "From: <sip:qbx@%s>%s" % (realm, (";tag=" + mt2.group(1)) if mt2 else "")
                mvia = re.search(r"^Via:.*", text, re.M).group(0)
                mcseq = re.search(r"^CSeq:.*", text, re.M).group(0)
                mok = ("SIP/2.0 200 OK\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\n%s\r\n"
                       "Content-Length: 0\r\n\r\n"
                       % (mvia, nto, nfrom, callid, mcseq))
                xfer([mok])
                print("notify=%s" % body_state)
            elif first.startswith("BYE"):
                mb = re.search(r"^CSeq:\s*(\d+)", text, re.M)
                bcseq = mb.group(1) if mb else "2"
                mt2 = re.search(r"^To:.*tag=([^\s;>]+)", text, re.M)
                mf = re.search(r"^From:.*tag=([^\s;>]+)", text, re.M)
                nto = "To: <sip:%s@%s:%d>%s" % (user, lip, lport, (";tag=" + mf.group(1)) if mf else "")
                nfrom = "From: <sip:qbx@%s>%s" % (realm, (";tag=" + mt2.group(1)) if mt2 else "")
                mvia = re.search(r"^Via:.*", text, re.M).group(0)
                bok = ("SIP/2.0 200 OK\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %s BYE\r\n"
                       "Content-Length: 0\r\n\r\n"
                       % (mvia, nto, nfrom, callid, bcseq))
                xfer([bok])
                print("bye_in=200")
                break
        print("notifies=%s" % (notified or "none"))
    # cleanup: BYE our dialog either way
    cseq += 1
    branch = "z9hG4bK-h-%s" % rand_tag()
    via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (lip, lport, branch)
    bye = ("BYE %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d BYE\r\n"
           "Max-Forwards: 70\r\nContent-Length: 0\r\n\r\n"
           % (remote, via, frm, to_full, callid, cseq))
    xfer([bye])
    resp2 = recv_match(branch, cseq, "BYE", 5.0)
    bye_line = resp2.split("\r\n")[0] if resp2 else "NO-RESPONSE"
    if re.match(r"^SIP/2.0 (401|407)", bye_line) and resp2:
        bauth = digest(resp2, "BYE", remote, user, pw, realm,
                       proxy=bye_line.startswith("SIP/2.0 407"))
        cseq += 1
        branch = "z9hG4bK-h-%s" % rand_tag()
        via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (lip, lport, branch)
        bye2 = ("BYE %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d BYE\r\n"
                "%s\r\nMax-Forwards: 70\r\nContent-Length: 0\r\n\r\n"
                % (remote, via, frm, to_full, callid, cseq, bauth))
        xfer([bye2])
        resp2 = recv_match(branch, cseq, "BYE", 5.0)
        bye_line = resp2.split("\r\n")[0] if resp2 else "NO-RESPONSE"
    print("bye=%s" % bye_line)
    sock.close()
    return 0 if rstatus.startswith("SIP/2.0 2") else 1


if __name__ == "__main__":
    sys.exit(main())
