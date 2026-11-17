#!/bin/sh
# ============================================================================
#  PKI dla RadSec (RADIUS over TLS, RFC 6614) - laboratorium
#
#  Uruchamiane jednorazowo przez usługę "pki" w docker-compose.yml.
#  Wynik trafia do wolumenu "radsec_pki" (montowanego w freeradius i client).
#
#    ca.pem / ca.key            Lab RadSec CA (zaufane przez obie strony)
#    server.pem / server.key    certyfikat serwera FreeRADIUS  (serverAuth)
#    client.pem / client.key    certyfikat NAS-a (radsecproxy) (clientAuth)
#    rogue-ca.pem, rogue.pem/.key  certyfikat z OBCEGO CA -> test odrzucenia
#    user-jan.pem / .key        certyfikat UŻYTKOWNIKA jan dla EAP-TLS (clientAuth)
#    user-ewa.pem / .key        drugi użytkownik: test check_cert_cn (podszycie)
#
#  Klucze: ECDSA P-256. Brakujące pliki są dorabiane przy każdym starcie,
#  istniejące zostają. Wszystko od nowa: docker compose down -v
# ============================================================================
set -eu

OUT="${1:-/pki}"
mkdir -p "$OUT"
cd "$OUT"

DAYS_CA=3650
DAYS_LEAF=825

new_key() {
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null
}

# $1 = nazwa pliku CA (bez rozszerzenia), $2 = CN
make_ca() {
    new_key "$1.key"
    openssl req -x509 -new -key "$1.key" -out "$1.pem" -days "$DAYS_CA" -sha256 \
        -subj "/O=AAA Lab/CN=$2" \
        -addext "basicConstraints=critical,CA:TRUE" \
        -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -addext "subjectKeyIdentifier=hash"
}

# $1 = nazwa, $2 = CN, $3 = subjectAltName, $4 = extendedKeyUsage, $5 = CA
make_leaf() {
    new_key "$1.key"
    openssl req -new -key "$1.key" -out "$1.csr" -subj "/O=AAA Lab/CN=$2"
    cat > "$1.ext" <<EOF
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=$4
subjectAltName=$3
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
EOF
    openssl x509 -req -in "$1.csr" -CA "$5.pem" -CAkey "$5.key" -CAcreateserial \
        -out "$1.pem" -days "$DAYS_LEAF" -sha256 -extfile "$1.ext" 2>/dev/null
    rm -f "$1.csr" "$1.ext"
}

# Tylko to, czego jeszcze nie ma
need() { [ ! -f "$1.pem" ]; }

need ca       && { echo "[pki] generuję Lab RadSec CA"; make_ca ca "AAA Lab RadSec CA"; }
need server   && { echo "[pki] certyfikat serwera: CN=freeradius";
                   make_leaf server "freeradius" "DNS:freeradius,IP:172.28.0.20" "serverAuth" ca; }
need client   && { echo "[pki] certyfikat NAS-a: CN=nas-client";
                   make_leaf client "nas-client" "DNS:client,IP:172.28.0.40" "clientAuth" ca; }
need rogue-ca && { echo "[pki] obce CA (intruz)"; make_ca rogue-ca "Rogue CA"; }
need rogue    && { echo "[pki] certyfikat intruza: CN=rogue-nas";
                   make_leaf rogue "rogue-nas" "DNS:rogue" "clientAuth" rogue-ca; }
need user-jan && { echo "[pki] certyfikat użytkownika (EAP-TLS): CN=jan";
                   make_leaf user-jan "jan" "email:jan@aaa.lab" "clientAuth" ca; }
need user-ewa && { echo "[pki] certyfikat użytkownika (EAP-TLS): CN=ewa";
                   make_leaf user-ewa "ewa" "email:ewa@aaa.lab" "clientAuth" ca; }

# Uprawnienia: certyfikaty publiczne, klucze tylko dla root + grupy freerad
chmod 0644 ./*.pem
chmod 0640 ./*.key
if getent group freerad >/dev/null 2>&1; then
    chgrp freerad ./*.key
fi
rm -f ./*.srl

echo "[pki] gotowe:"
for c in ca server client rogue user-jan user-ewa; do
    openssl x509 -in "$c.pem" -noout -subject -issuer -enddate | sed "s/^/[pki]   $c: /"
done
