#!/usr/bin/env python3
"""REGISTER helper: register -> hold -> unregister. usage: <proxy> <port> <user> <domain> <password> <hold_seconds>
prints register=/unregister= status lines; never prints credentials.
exit 0 iff register 200 and unregister 200."""
import hashlib, random, re, socket, sys, time

def md5(s): return hashlib.md5(s.encode()).hexdigest()
def rand_tag(): return format(random.getrandbits(32), "08x")

def digest(header, method, uri, user, pw, proxy=False):
    # RFC 3261 s22 (mirrors sip_caller.py): 407 (Proxy-Authenticate) ->
    # Proxy-Authorization; 401 (WWW-Authenticate) -> Authorization.
    scheme = "Proxy-Authorization" if proxy else "Authorization"
    realm = re.search(r'realm="([^"]+)"', header)
    nonce = re.search(r'nonce="([^"]+)"', header)
    qop = re.search(r'qop="([^"]+)"', header)
    realm = realm.group(1) if realm else ""
    nonce = nonce.group(1) if nonce else ""
    ha1 = md5("%s:%s:%s" % (user, realm, pw)); ha2 = md5("%s:%s" % (method, uri))
    if qop and "auth" in qop.group(1):
        nc, cnonce = "00000001", rand_tag()
        resp = md5("%s:%s:%s:%s:%s:%s" % (ha1, nonce, nc, cnonce, "auth", ha2))
        return ('%s: Digest username="%s", realm="%s", nonce="%s", uri="%s", '
                'response="%s", algorithm=MD5, qop=auth, nc=%s, cnonce="%s"'
                % (scheme, user, realm, nonce, uri, resp, nc, cnonce))
    resp = md5("%s:%s:%s" % (ha1, nonce, ha2))
    return ('%s: Digest username="%s", realm="%s", nonce="%s", uri="%s", '
            'response="%s", algorithm=MD5' % (scheme, user, realm, nonce, uri, resp))

class Sip(object):
    def __init__(self, proxy, port):
        self.proxy, self.port = proxy, port
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("", 0)); self.sock.connect((proxy, port))
        self.local_ip, self.local_port = self.sock.getsockname()[0], self.sock.getsockname()[1]
        self.sock.settimeout(0.3)
    def send(self, msg): self.sock.sendto(msg.encode(), (self.proxy, self.port))
    def recv_status(self, timeout=6.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            try: data, _ = self.sock.recvfrom(65535)
            except socket.timeout: continue
            except OSError: break     # ICMP refusal is final: no response will ever arrive
            text = data.decode(errors="replace"); first = text.split("\r\n")[0]
            if re.match(r"^SIP/2.0 \d\d\d", first): return text
        return ""

def build_register(s, uri, user, domain, cseq, branch, tag, callid, expires, auth=None):
    lines = ["REGISTER %s SIP/2.0" % uri,
             "Via: SIP/2.0/UDP %s:%d;rport;branch=%s" % (s.local_ip, s.local_port, branch),
             "From: <sip:%s@%s>;tag=%s" % (user, domain, tag),
             "To: <sip:%s@%s>" % (user, domain),
             "Call-ID: %s" % callid, "CSeq: %d REGISTER" % cseq,
             "Contact: <sip:%s@%s:%d>" % (user, s.local_ip, s.local_port),
             "Max-Forwards: 70", "Expires: %d" % expires,
             "User-Agent: QBX-Harness", "Content-Length: 0"]
    if auth: lines.insert(7, auth)
    return "\r\n".join(lines) + "\r\n\r\n"

def register_round(s, uri, user, domain, pw, expires, start_cseq):
    cseq = start_cseq
    callid = "%d@harness-reg" % random.getrandbits(48)
    tag = rand_tag()
    s.send(build_register(s, uri, user, domain, cseq, "z9hG4bK-r-%s" % rand_tag(), tag, callid, expires))
    resp = s.recv_status()
    status = resp.split("\r\n")[0] if resp else "NO-RESPONSE"
    if status.startswith(("SIP/2.0 401", "SIP/2.0 407")):
        auth = digest(resp, "REGISTER", uri, user, pw, proxy=status.startswith("SIP/2.0 407"))
        s.send(build_register(s, uri, user, domain, cseq + 1,
                              "z9hG4bK-r-%s" % rand_tag(), tag, callid, expires, auth=auth))
        resp = s.recv_status()
        status = resp.split("\r\n")[0] if resp else "NO-RESPONSE"
    return status.startswith("SIP/2.0 200"), status

def main():
    proxy, port, user, domain, pw = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4], sys.argv[5]
    hold = float(sys.argv[6]); uri = "sip:%s" % domain
    s = Sip(proxy, port)
    ok, status = register_round(s, uri, user, domain, pw, 300, 1)
    print("register=%s" % status)
    if not ok: return 1
    print("registered user=%s hold=%ss" % (user, int(hold)))
    time.sleep(hold)
    ok, status = register_round(s, uri, user, domain, pw, 0, 900)
    print("unregister=%s" % status)
    s.sock.close()
    return 0 if ok else 2

if __name__ == "__main__":
    sys.exit(main())
