#!/usr/bin/env python3
"""
Minimalny klient RadSec (RADIUS over TLS, RFC 6614) do demonstracji w Wiresharku.

Wysyła jedno Access-Request (PAP) przez TLS do freeradius:2083 i ZAPISUJE KLUCZE
SESJI TLS do pliku (format NSS keylog, jak SSLKEYLOGFILE w przeglądarkach).
Wireshark z tym plikiem odszyfruje ruch i pokaże pakiet RADIUS wewnątrz tunelu.

  python3 /radsec/radsec_client.py jan jan123
  python3 /radsec/radsec_client.py jan jan123 --keylog /tmp/keys.log --host freeradius
"""
import argparse
import hashlib
import hmac
import os
import socket
import ssl
import struct

PKI = "/etc/radsecproxy/pki"
SECRET = b"radsec"  # RFC 6614: stały sekret dla RADIUS/TLS
CODES = {2: "Access-Accept", 3: "Access-Reject", 11: "Access-Challenge"}


def attr(t, value):
    return struct.pack("!BB", t, len(value) + 2) + value


def hide_password(password, authenticator, secret):
    """User-Password wg RFC 2865 5.2 (XOR z MD5 sekretu)."""
    p = password.encode()
    p = p.ljust(max(16, (len(p) + 15) // 16 * 16), b"\x00")
    out, prev = b"", authenticator
    for i in range(0, len(p), 16):
        b = hashlib.md5(secret + prev).digest()
        chunk = bytes(x ^ y for x, y in zip(p[i:i + 16], b))
        out += chunk
        prev = chunk
    return out


def access_request(user, password, nas_ip):
    ident = os.urandom(1)[0]
    auth = os.urandom(16)
    attrs = (
        attr(1, user.encode())                                  # User-Name
        + attr(2, hide_password(password, auth, SECRET))        # User-Password
        + attr(4, socket.inet_aton(nas_ip))                     # NAS-IP-Address
        + attr(32, b"radsec-demo-client")                       # NAS-Identifier
    )
    ma_placeholder = attr(80, b"\x00" * 16)                     # Message-Authenticator
    length = 20 + len(attrs) + len(ma_placeholder)
    pkt = struct.pack("!BBH", 1, ident, length) + auth + attrs + ma_placeholder
    ma = hmac.new(SECRET, pkt, hashlib.md5).digest()
    return pkt[:-16] + ma, ident


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("serwer zamknął połączenie")
        buf += chunk
    return buf


def main():
    ap = argparse.ArgumentParser(description="Klient RadSec z zapisem kluczy TLS")
    ap.add_argument("user")
    ap.add_argument("password")
    ap.add_argument("--host", default="freeradius")
    ap.add_argument("--port", type=int, default=2083)
    ap.add_argument("--keylog", default="/tmp/radsec-keys.log")
    ap.add_argument("--cert", default=f"{PKI}/client.pem")
    ap.add_argument("--key", default=f"{PKI}/client.key")
    ap.add_argument("--ca", default=f"{PKI}/ca.pem")
    ap.add_argument("--nas-ip", default="172.28.0.40")
    a = ap.parse_args()

    ctx = ssl.create_default_context(ssl.Purpose.SERVER_AUTH, cafile=a.ca)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_2
    ctx.load_cert_chain(a.cert, a.key)
    ctx.keylog_filename = a.keylog  # <- klucze sesji dla Wiresharka

    with socket.create_connection((a.host, a.port), timeout=10) as raw:
        with ctx.wrap_socket(raw, server_hostname=a.host) as tls:
            print(f"TLS: {tls.version()} {tls.cipher()[0]}, "
                  f"serwer: {dict(x[0] for x in tls.getpeercert()['subject'])['commonName']}")
            pkt, ident = access_request(a.user, a.password, a.nas_ip)
            tls.sendall(pkt)
            print(f"Wysłano Access-Request id={ident} user={a.user}")
            hdr = recv_exact(tls, 20)
            code, rid, length = struct.unpack("!BBH", hdr[:4])
            recv_exact(tls, length - 20)
            print(f"Odebrano {CODES.get(code, code)} id={rid}")
    print(f"Klucze TLS dopisane do: {a.keylog}")


if __name__ == "__main__":
    main()
