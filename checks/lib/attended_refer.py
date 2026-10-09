#!/usr/bin/env python3
"""Attended-transfer 2-dialog vehicle: leg A + leg B INVITE qbx-test-echo,
REFER on A with Replaces pointing at B (RFC 3891/3515 attended transfer).

usage: attended_refer.py <proxy> <port> <user> <pass> <realm> [seconds]
       attended_refer.py --selftest | --mock
prints status lines only (never credentials). Verdict contract (exact):
Sofia sends NO NOTIFY for an executed attended REFER, so a NOTIFY-sipfrag-2xx
is sufficient but NOT necessary. COMPLETED (exit 0) requires a
transfer-specific signal inseparable from cleanup — NOTIFY-2xx OR the FS-log
ATTENDED_TRANSFER hangup cause on our own uuids — AND full CDR attribution
(both legs completed with a named tenant subscription). REFER accepted but
signal/attribution incomplete -> TRANSFER-UNPROVEN (exit 1, never 0).
REFER not accepted -> FAILED (exit 1). Foreign channels present -> exit 2.

Own legs only: both dialogs carry our Call-IDs; cleanup BYEs only those
Call-IDs; before/after `show channels` 0-total gate (exit 2 if foreign
channels present — never touches them). Consistent with refer_probe.py
(Proxy-Authorization on 407, Via-branch+CSeq recv_match, To-tag learning).
"""
import hashlib
import json
import random
import re
import socket
import subprocess
import sys
import time


def md5(s):
    return hashlib.md5(s.encode()).hexdigest()


def rand_tag():
    return format(random.getrandbits(32), "08x")


def digest(header, method, uri, user, pw, realm, proxy=False):
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


def build_refer_to_replaces(target_uri, other_callid, other_to_tag, other_from_tag):
    """Refer-To value embedding RFC 3891 Replaces for the other dialog."""
    return ("<%s?Replaces=%s;to-tag=%s;from-tag=%s>"
            % (target_uri, other_callid, other_to_tag, other_from_tag))


def notify_outcome(text):
    """Classify a NOTIFY body (message/sipfrag): completed/failed/pending."""
    m = re.findall(r"SIP/2\.0\s+(\d\d\d)", text)
    if not m:
        return "pending"
    code = int(m[-1])
    if 200 <= code < 300:
        return "completed"
    if code >= 400:
        return "failed"
    return "pending"


def pg(query):
    """Read-only PG query via host nsenter (never prints credentials)."""
    import os
    try:
        dburl = os.environ.get(
            "DATABASE_URL",
            [l.split("=", 1)[1].strip() for l in open("/root/QBX/.env")
             if l.startswith("DATABASE_URL=")][0])
        out = subprocess.run(["nsenter", "-t", "1", "-n", "psql", dburl,
                              "-tAX", "-F|", "-c", query],
                             capture_output=True, text=True, timeout=20)
        return out.stdout.strip()
    except Exception as e:
        return "PG-ERROR %s" % e


def cdr_attribution(uuids):
    """Tenant attribution per leg: cdrs.call_id (=FS uuid) -> subscription."""
    rows = {}
    for name, uuid in uuids.items():
        r = pg("SELECT status,subscription_id FROM cdrs WHERE call_id='%s'" % uuid)
        sub = "none"
        if r and not r.startswith("PG-ERROR"):
            parts = r.splitlines()[0].split("|")
            status = parts[0] if len(parts) > 0 else "?"
            subid = parts[1] if len(parts) > 1 else ""
            sub = pg("SELECT name FROM subscriptions WHERE id='%s'" % subid).splitlines()
            sub = sub[0] if sub else "?"
            rows[name] = (status, sub)
            print("cdr_%s=%s sub=%s uuid=%s" % (name, status, sub, uuid[:8]))
        else:
            rows[name] = ("missing", "none")
            print("cdr_%s=missing uuid=%s" % (name, uuid[:8]))
    return rows


def match_transfer_signal(log_text, uuids):
    """Pure: FS-log lines carrying the ATTENDED_TRANSFER hangup cause on our
    own uuids. This cause is emitted only when Sofia executes the transfer
    (inseparable from the transfer cleanup itself)."""
    return [l for l in (log_text or "").splitlines()
            if "ATTENDED_TRANSFER" in l and any(u in l for u in uuids.values())]


def compute_verdict(outcome, server_done, cdr_ok, cdr_checked, refer_accepted):
    """Verdict contract (exact):
    transfer_signal = NOTIFY-sipfrag-2xx OR FS ATTENDED_TRANSFER on own uuids.
    COMPLETED (exit 0) = transfer_signal AND (cdr_ok if cdr_checked).
    TRANSFER-UNPROVEN (exit 1) = REFER accepted but signal/attribution
      incomplete (never exit 0). FAILED (exit 1) = REFER not accepted."""
    signal = (outcome == "completed") or bool(server_done)
    if (signal and cdr_ok) if cdr_checked else signal:
        return ("COMPLETED", 0)
    if refer_accepted:
        return ("TRANSFER-UNPROVEN", 1)
    return ("FAILED", 1)


def fs_transfer_verdict(uuids):
    """Server-side completion: ATTENDED_TRANSFER hangup on our uuids."""
    try:
        out = subprocess.run(["nsenter", "-t", "1", "-n", "docker", "exec",
                              "telecom-freeswitch-1", "grep", "-a",
                              "ATTENDED_TRANSFER", "/var/log/freeswitch/freeswitch.log"],
                             capture_output=True, text=True, timeout=30).stdout
    except Exception as e:
        print("fsverdict=unreadable %s" % e)
        return False
    hit = match_transfer_signal(out, uuids)
    for h in hit[-3:]:
        print("fsverdict=%s" % h[:200])
    return len(hit) > 0


def esl(cmd):
    try:
        out = subprocess.run(["nsenter", "-t", "1", "-n", "python3",
                              "/root/esl_api.py", cmd],
                             capture_output=True, text=True, timeout=15)
        return out.stdout.strip()
    except Exception as e:
        return "ESL-ERROR %s" % e


def channels_total():
    m = re.search(r"(\d+)\s+total", esl("show channels"))
    return int(m.group(1)) if m else -1


class Leg(object):
    """One owned SIP dialog (own socket, own Call-ID)."""

    def __init__(self, proxy, port):
        self.proxy, self.port = proxy, port
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("", 0))
        self.sock.connect((proxy, port))
        self.lip, self.lport = self.sock.getsockname()[0], self.sock.getsockname()[1]
        self.sock.settimeout(0.3)
        self.callid = "%d@attended" % random.getrandbits(48)
        self.tag = rand_tag()
        self.cseq = 0
        self.to_tag = ""
        self.remote = ""
        self.via = ""
        self.frm = self.to_full = self.contact = ""

    def send(self, msg):
        self.sock.sendto(msg.encode(), (self.proxy, self.port))

    def recv_match(self, branch, cseq, method, timeout):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                data, _ = self.sock.recvfrom(65535)
            except socket.timeout:
                continue
            text = data.decode(errors="replace")
            if text.startswith("SIP/2.0 1"):
                continue
            if not re.match(r"^SIP/2\.0 \d\d\d", text.split("\r\n")[0]):
                # stash async (NOTIFY/BYE) for later drain; not our transaction
                self.stash.append(text)
                continue
            vb = re.search(r"branch=([^;\s]+)", text)
            cs = re.search(r"^CSeq:\s*(\S+.*)$", text, re.M)
            if vb and cs and vb.group(1) == branch and cs.group(1).strip() == "%d %s" % (cseq, method):
                return text
        return ""

    def invite(self, uri, user, pw, realm):
        self.stash = []
        sdp = ("v=0\r\no=- %d %d IN IP4 %s\r\ns=-\r\nc=IN IP4 %s\r\nt=0 0\r\n"
               "m=audio %d RTP/AVP 0 8\r\na=rtpmap:0 PCMU/8000\r\na=rtpmap:8 PCMA/8000\r\n"
               % (random.getrandbits(32), random.getrandbits(32),
                  self.lip, self.lip, 15000 + random.getrandbits(12)))
        self.frm = "From: <sip:%s@%s>;tag=%s" % (user, realm, self.tag)
        self.to_full = "To: <%s>" % uri
        self.contact = "<sip:%s@%s:%d>" % (user, self.lip, self.lport)
        self.cseq = 1
        branch = "z9hG4bK-h-%s" % rand_tag()
        self.via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (self.lip, self.lport, branch)
        inv = ("INVITE %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d INVITE\r\n"
               "Contact: %s\r\nMax-Forwards: 70\r\nContent-Type: application/sdp\r\n"
               "Content-Length: %d\r\nUser-Agent: QBX-AttendedProbe\r\n\r\n%s"
               % (uri, self.via, self.frm, self.to_full, self.callid,
                  self.cseq, self.contact, len(sdp), sdp))
        self.send(inv)
        resp = self.recv_match(branch, self.cseq, "INVITE", 8.0)
        status = resp.split("\r\n")[0] if resp else "NO-RESPONSE"
        if re.match(r"^SIP/2\.0 (401|407)", status) and resp:
            auth = digest(resp, "INVITE", uri, user, pw, realm,
                          proxy=status.startswith("SIP/2.0 407"))
            self.cseq += 1
            branch = "z9hG4bK-h-%s" % rand_tag()
            self.via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (self.lip, self.lport, branch)
            inv2 = ("INVITE %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d INVITE\r\n"
                    "%s\r\nContact: %s\r\nMax-Forwards: 70\r\nContent-Type: application/sdp\r\n"
                    "Content-Length: %d\r\n\r\n%s"
                    % (uri, self.via, self.frm, self.to_full, self.callid,
                       self.cseq, auth, self.contact, len(sdp), sdp))
            self.send(inv2)
            resp = self.recv_match(branch, self.cseq, "INVITE", 8.0)
            status = resp.split("\r\n")[0] if resp else "NO-RESPONSE"
        if status.startswith("SIP/2.0 200") and resp:
            mt = re.search(r"^To:.*tag=([^\s;>]+)", resp, re.M)
            self.to_tag = mt.group(1) if mt else ""
            mc = re.search(r"^Contact:\s*<?([^>\s]+)", resp, re.M)
            self.remote = mc.group(1) if mc else uri
            self.to_full = "To: <%s>;tag=%s" % (uri, self.to_tag) if self.to_tag else self.to_full
            ack = ("ACK %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d ACK\r\n"
                   "Max-Forwards: 70\r\nContent-Length: 0\r\n\r\n"
                   % (self.remote, self.via, self.frm, self.to_full, self.callid, self.cseq))
            self.send(ack)
        return status

    def bye(self, user, pw, realm):
        self.cseq += 1
        branch = "z9hG4bK-h-%s" % rand_tag()
        via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (self.lip, self.lport, branch)
        bye = ("BYE %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d BYE\r\n"
               "Max-Forwards: 70\r\nContent-Length: 0\r\n\r\n"
               % (self.remote or "sip:bye@invalid", via, self.frm, self.to_full,
                  self.callid, self.cseq))
        self.send(bye)
        resp = self.recv_match(branch, self.cseq, "BYE", 5.0)
        line = resp.split("\r\n")[0] if resp else "NO-RESPONSE"
        if re.match(r"^SIP/2\.0 (401|407)", line) and resp:
            auth = digest(resp, "BYE", self.remote, user, pw, realm,
                          proxy=line.startswith("SIP/2.0 407"))
            self.cseq += 1
            branch = "z9hG4bK-h-%s" % rand_tag()
            via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (self.lip, self.lport, branch)
            bye2 = ("BYE %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d BYE\r\n"
                    "%s\r\nMax-Forwards: 70\r\nContent-Length: 0\r\n\r\n"
                    % (self.remote, via, self.frm, self.to_full, self.callid, self.cseq, auth))
            self.send(bye2)
            resp = self.recv_match(branch, self.cseq, "BYE", 5.0)
            line = resp.split("\r\n")[0] if resp else "NO-RESPONSE"
        return line

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def selftest():
    rt = build_refer_to_replaces("sip:qbx-test-echo@qbx.qubickle.com", "c1@x", "toT", "fromT")
    assert "Replaces=" in rt and "c1%40x" not in rt, rt
    assert "to-tag=toT" in rt and "from-tag=fromT" in rt, rt
    assert notify_outcome("SIP/2.0 200 OK\r\nContent-Type: message/sipfrag\r\n\r\nSIP/2.0 200 OK") == "completed"
    assert notify_outcome("SIP/2.0 403 Forbidden\r\n\r\nSIP/2.0 403 Forbidden") == "failed"
    assert notify_outcome("SIP/2.0 100 Trying\r\n\r\nSIP/2.0 100 Trying") == "pending"
    # verdict contract (tightened): COMPLETED needs a transfer-specific
    # signal (NOTIFY-2xx or FS ATTENDED_TRANSFER) AND full CDR attribution.
    assert compute_verdict("completed", False, True, True, True) == ("COMPLETED", 0)
    assert compute_verdict("none", True, True, True, True) == ("COMPLETED", 0)
    assert compute_verdict("none", True, False, True, True) == ("TRANSFER-UNPROVEN", 1)
    assert compute_verdict("none", False, True, True, True) == ("TRANSFER-UNPROVEN", 1)
    assert compute_verdict("none", False, False, True, True) == ("TRANSFER-UNPROVEN", 1)
    assert compute_verdict("none", False, False, True, False) == ("FAILED", 1)
    assert compute_verdict("completed", False, False, False, True) == ("COMPLETED", 0)
    good = ("uuid-1 2026-10-09 16:28:24.001843 [NOTICE] switch_ivr.c:1072 "
            "Hangup sofia/internal/4000@qbx.qubickle.com [CS_PARK] [ATTENDED_TRANSFER]")
    bad = ("uuid-9 2026-10-09 16:28:24.001843 [NOTICE] switch_core_session.c:1762 "
            "Session 5601 Ended")
    assert match_transfer_signal(good + "\n" + bad, {"A": "uuid-1"}) != []
    assert match_transfer_signal(bad, {"A": "uuid-1"}) == []
    assert match_transfer_signal(good, {"A": "uuid-2"}) == []
    print("selftest=ok refer_to=%s" % rt)
    return 0


def mock_peer(port_file, log):
    """Hermetic 2-dialog SIP peer: 200 OK to INVITE, 202 to REFER, NOTIFY 200."""
    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.bind(("127.0.0.1", 0))
    srv.settimeout(0.2)
    with open(port_file, "w") as fh:
        fh.write(str(srv.getsockname()[1]))
    dialogs = {}
    deadline = time.time() + 25
    while time.time() < deadline:
        try:
            data, addr = srv.recvfrom(65535)
        except socket.timeout:
            continue
        text = data.decode(errors="replace")
        first = text.split("\r\n")[0]
        cid = re.search(r"^Call-ID:\s*(\S+)", text, re.M)
        cid = cid.group(1) if cid else "?"
        cseq = re.search(r"^CSeq:\s*(\d+)\s+(\w+)", text, re.M)
        n, m = (cseq.group(1), cseq.group(2)) if cseq else ("1", "?")
        via = re.search(r"^Via:.*", text, re.M).group(0)
        frm = re.search(r"^From:.*", text, re.M).group(0)
        to = re.search(r"^To:.*", text, re.M).group(0)
        log.append("%s %s" % (m, cid))

        def resp(code, phrase, extra=""):
            return ("SIP/2.0 %d %s\r\n%s\r\nTo: %s%s\r\nFrom: %s\r\nCall-ID: %s\r\n"
                    "CSeq: %s %s\r\nContent-Length: 0\r\n%s\r\n"
                    % (code, phrase, via, to,
                       "" if "tag=" in to else ";tag=mock-%s" % rand_tag(),
                       frm, cid, n, m, extra))

        def send(msg):
            srv.sendto(msg.encode(), addr)
        if m == "INVITE":
            dialogs[cid] = (frm, to)
            send(resp(200, "OK", "Contact: <sip:mock@127.0.0.1>\r\n"
                      "Content-Type: application/sdp\r\n"))
        elif m == "REFER":
            has_replaces = "Replaces=" in text
            send(resp(202, "Accepted"))
            if has_replaces:
                nto = "To: %s" % frm
                nfrom = "From: %s;tag=mock-n" % to.split(";")[0]
                body = "SIP/2.0 200 OK"
                send(("NOTIFY sip:n@127.0.0.1 SIP/2.0\r\n%s\r\n%s\r\n%s\r\n"
                      "Call-ID: %s\r\nCSeq: 1 NOTIFY\r\n"
                      "Content-Type: message/sipfrag\r\nContent-Length: %d\r\n\r\n%s"
                      % (via, nto, nfrom, cid, len(body), body)))
        elif m == "BYE":
            send(resp(200, "OK"))
    srv.close()


def mock_run():
    import threading
    port_file = "/tmp/attended-mock.port"
    try:
        import os
        os.unlink(port_file)  # never trust a stale port from a prior run
    except OSError:
        pass
    log = []
    t = threading.Thread(target=mock_peer, args=(port_file, log), daemon=True)
    t.start()
    for _ in range(50):
        try:
            port = int(open(port_file).read().strip())
            break
        except Exception:
            time.sleep(0.1)
    else:
        print("mock=peer-never-up")
        return 1
    rc = drive("127.0.0.1", port, "u", "p", "mock.invalid", hold=2.0,
               check_channels=False, check_cdr=False)
    print("mock_dialogs=%s" % sorted(set(log)))
    if rc != 0:
        print("mock_verdict_path=main-drive-failed")
        return 1
    # verdict-path coverage with canned FS-log + PG (exercises the exact
    # assertions the live verdict relies on, without live deps).
    good = ("u-a 2026-10-09 16:28:24.001843 [NOTICE] switch_ivr.c:1072 Hangup "
            "sofia/internal/4000@qbx.qubickle.com [CS_PARK] [ATTENDED_TRANSFER]")
    if not match_transfer_signal(good, {"A": "u-a", "B": "u-b"}):
        print("mock_verdict_path=fs-signal-missed")
        return 1
    if match_transfer_signal(good, {"A": "u-z"}):
        print("mock_verdict_path=fs-signal-false-positive")
        return 1
    g = globals()
    old_pg = g["pg"]
    g["pg"] = lambda q: ("completed|sub-1" if "FROM cdrs" in q else "Acme Corp")
    try:
        rows = cdr_attribution({"A": "u-a", "B": "u-b"})
    finally:
        g["pg"] = old_pg
    if not all(v == ("completed", "Acme Corp") for v in rows.values()):
        print("mock_verdict_path=cdr-parse-failed rows=%s" % rows)
        return 1
    v, c = compute_verdict("none", True, True, True, True)
    if (v, c) != ("COMPLETED", 0):
        print("mock_verdict_path=verdict-failed")
        return 1
    # live-verdict negative through the real drive: no NOTIFY from the peer
    # here (already consumed), no CDR check -> TRANSFER-UNPROVEN, rc=1.
    rc2 = drive("127.0.0.1", port, "u", "p", "mock.invalid", hold=1.0,
                check_channels=False, check_cdr=True)
    print("mock_unproven_rc=%d" % rc2)
    if rc2 != 1:
        print("mock_verdict_path=unproven-not-1")
        return 1
    print("mock_verdict_path=ok")
    return 0


def find_own_uuids(callids):
    """Map our SIP Call-IDs to FS channel UUIDs (read-only; own legs only)."""
    found = {}
    try:
        out = esl("show channels")
    except Exception:
        return found
    for line in out.splitlines():
        m = re.match(r"^([0-9a-f]{8}-[0-9a-f-]{27})", line)
        if not m:
            continue
        uuid = m.group(1)
        try:
            dump = esl("uuid_dump %s json" % uuid)
            d = json.loads(dump) if dump else {}
        except Exception:
            continue
        cid = d.get("variable_sip_call_id", "")
        if cid in callids:
            found[cid] = (uuid, d.get("variable_qbx_tenant_id")
                          or d.get("variable_tenant_id") or "unknown")
    return found


def drive(proxy, port, user, pw, realm, hold=6.0, check_channels=True, check_cdr=True,
          bridge=True):
    target = "qbx-test-echo"
    uri = "sip:%s@%s" % (target, realm)
    if check_channels:
        tot = channels_total()
        print("channels_before=%d" % tot)
        if tot != 0:
            return 2
    legs = []
    try:
        a, b = Leg(proxy, port), Leg(proxy, port)
        legs = [a, b]
        own_uuids = {}  # our Call-ID -> (FS uuid, tenant): captured pre-REFER
        sa = a.invite(uri, user, pw, realm)
        print("legA_invite=%s callid=%s" % (sa, a.callid))
        if not sa.startswith("SIP/2.0 200"):
            return 1
        sb = b.invite(uri, user, pw, realm)
        print("legB_invite=%s callid=%s" % (sb, b.callid))
        if not sb.startswith("SIP/2.0 200"):
            return 1
        time.sleep(1.0)
        # bridge step: put our two FS channels in a bridge so the Replaces
        # REFER is transferable (own legs only, matched by our Call-IDs).
        bridged = "skipped"
        if bridge:
            ids = find_own_uuids({a.callid: "A", b.callid: "B"})
            own_uuids = dict(ids)
            print("own_uuids=%d tenant=%s" % (
                len(ids), ",".join(sorted(set(v[1] for v in ids.values()))) or "none"))
            if len(ids) == 2:
                ua, ub = ids[a.callid][0], ids[b.callid][0]
                br = esl("uuid_bridge %s %s" % (ua, ub))
                bridged = (br.strip().splitlines() or ["empty"])[0][:120]
                print("bridge=%s" % bridged)
                time.sleep(1.0)
            else:
                print("bridge=not-found want=2")
        # attended REFER on A: Replaces points at the B dialog
        a.cseq += 1
        branch = "z9hG4bK-h-%s" % rand_tag()
        via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (a.lip, a.lport, branch)
        refer_to = build_refer_to_replaces(uri, b.callid, b.to_tag, b.tag)
        refer = ("REFER %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d REFER\r\n"
                 "Contact: %s\r\nMax-Forwards: 70\r\nRefer-To: %s\r\n"
                 "Referred-By: <sip:%s@%s>\r\nContent-Length: 0\r\n\r\n"
                 % (a.remote, via, a.frm, a.to_full, a.callid, a.cseq,
                    a.contact, refer_to, user, realm))
        a.send(refer)
        rresp = a.recv_match(branch, a.cseq, "REFER", 8.0)
        rstatus = rresp.split("\r\n")[0] if rresp else "NO-RESPONSE"
        print("refer=%s" % rstatus)
        if re.match(r"^SIP/2\.0 (401|407)", rstatus) and rresp:
            rauth = digest(rresp, "REFER", a.remote, user, pw, realm,
                           proxy=rstatus.startswith("SIP/2.0 407"))
            a.cseq += 1
            branch = "z9hG4bK-h-%s" % rand_tag()
            via = "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (a.lip, a.lport, branch)
            refer2 = ("REFER %s SIP/2.0\r\n%s\r\n%s\r\n%s\r\nCall-ID: %s\r\nCSeq: %d REFER\r\n"
                      "%s\r\nContact: %s\r\nMax-Forwards: 70\r\nRefer-To: %s\r\n"
                      "Referred-By: <sip:%s@%s>\r\nContent-Length: 0\r\n\r\n"
                      % (a.remote, via, a.frm, a.to_full, a.callid, a.cseq,
                         rauth, a.contact, refer_to, user, realm))
            a.send(refer2)
            rresp = a.recv_match(branch, a.cseq, "REFER", 8.0)
            rstatus = rresp.split("\r\n")[0] if rresp else "NO-RESPONSE"
            print("refer_auth=%s" % rstatus)
        outcome = "none"
        fs_reject = ""
        if rstatus.startswith("SIP/2.0 2"):
            deadline = time.time() + hold
            while time.time() < deadline:
                for leg in legs:
                    leg.sock.settimeout(0.3)
                    try:
                        data, _ = leg.sock.recvfrom(65535)
                    except socket.timeout:
                        continue
                    text = data.decode(errors="replace")
                    first = text.split("\r\n")[0]
                    if first.startswith("NOTIFY"):
                        outcome = notify_outcome(text)
                        print("notify_%s=%s" % ("A" if leg is a else "B", outcome))
                        mvia = re.search(r"^Via:.*", text, re.M).group(0)
                        mcseq = re.search(r"^CSeq:.*", text, re.M).group(0)
                        ok = ("SIP/2.0 200 OK\r\n%s\r\nTo: %s\r\nFrom: %s\r\nCall-ID: %s\r\n%s\r\n"
                              "Content-Length: 0\r\n\r\n"
                              % (mvia, leg.frm, leg.to_full, leg.callid, mcseq))
                        leg.send(ok)
                        if outcome == "completed":
                            deadline = 0
                            break
                    elif "Cannot Blind Transfer" in text or "Cannot Attended" in text:
                        fs_reject = text.split("\r\n")[0]
                if outcome == "completed":
                    break
            print("transfer_outcome=%s" % outcome)
            # FS log evidence of correct/incorrect rejection
            try:
                flog = subprocess.run(["nsenter", "-t", "1", "-n", "tail", "-n", "200",
                                       "/var/log/freeswitch/freeswitch.log"],
                                      capture_output=True, text=True, timeout=15).stdout
                hits = [l.strip() for l in flog.splitlines()
                        if "ransfer" in l and ("attended" in l.lower() or a.callid[:8] in l
                                               or b.callid[:8] in l or "Blind Transfer" in l)]
                for h in hits[-5:]:
                    print("fslog=%s" % h[:200])
            except Exception as e:
                print("fslog=unreadable %s" % e)
            if fs_reject:
                print("fs_reject=%s" % fs_reject)
        # CDR tenant attribution for both legs (read-only PG join;
        # own FS uuids captured pre-REFER survive the transfer hangup).
        cdr_ok = False
        if check_cdr:
            if not own_uuids:
                own_uuids = find_own_uuids({a.callid: "A", b.callid: "B"})
            uuidmap = {"A": own_uuids.get(a.callid, ("", ""))[0],
                       "B": own_uuids.get(b.callid, ("", ""))[0]}
            uuidmap = {k: v for k, v in uuidmap.items() if v}
            rows = cdr_attribution(uuidmap) if uuidmap else {}
            cdr_ok = (len(rows) == 2
                      and all(v[0] == "completed" and v[1] not in ("?", "none")
                              for v in rows.values()))
            # server-side completion: Sofia sends no NOTIFY on attended
            # transfer; the ATTENDED_TRANSFER hangup on our uuids is the
            # verdict (proven live).
            server_done = fs_transfer_verdict(
                {k: v for k, v in uuidmap.items()}) if uuidmap else False
        else:
            server_done = False
        verdict, rc = compute_verdict(outcome, server_done, cdr_ok,
                                       check_cdr, rstatus.startswith("SIP/2.0 2"))
        print("verdict=%s notify=%s server=%s cdr=%s" % (
            verdict, outcome, server_done if check_cdr else "n/a", cdr_ok if check_cdr else "n/a"))
        return rc
    finally:
        for leg in legs:  # trap: kill ONLY our own Call-IDs on all paths
            try:
                if leg.remote:
                    bl = leg.bye(user, pw, realm)
                    print("bye_%s=%s" % (leg.callid[:8], bl))
            except Exception as e:
                print("bye_%s=error %s" % (leg.callid[:8], e))
            leg.close()
        if check_channels:
            time.sleep(2)
            tot = channels_total()
            print("channels_after=%d" % tot)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        return selftest()
    if len(sys.argv) > 1 and sys.argv[1] == "--mock":
        return mock_run()
    proxy, port = sys.argv[1], int(sys.argv[2])
    user, pw, realm = sys.argv[3], sys.argv[4], sys.argv[5]
    hold = float(sys.argv[6]) if len(sys.argv) > 6 else 6.0
    return drive(proxy, port, user, pw, realm, hold=hold)


if __name__ == "__main__":
    sys.exit(main())
