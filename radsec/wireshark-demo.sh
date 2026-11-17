#!/bin/sh
# ============================================================================
#  Nagranie ruchu do Wiresharka: RADIUS/UDP vs RadSec (TLS 1.3)
#
#  Uruchom na kontenerze client:
#    docker compose exec client sh /radsec/wireshark-demo.sh
#  Potem skopiuj na hosta:
#    docker compose cp client:/tmp/radsec-demo.pcap .
#    docker compose cp client:/tmp/radsec-keys.log .
#
#  Kolejność w nagraniu (łatwo znaleźć w Wiresharku):
#    1. RADIUS/UDP 1812           - jawny tekst
#    2. RadSec przez radsecproxy  - szyfrowany, bez kluczy
#    3. RadSec Access-Accept      - klucze zapisane -> do odszyfrowania
#    4. RadSec Access-Reject      - złe hasło, klucze zapisane
#    5. "intruz" z obcego CA      - serwer zrywa handshake (Alert: Unknown CA)
# ============================================================================
set -u
PKI=/etc/radsecproxy/pki
PCAP=/tmp/radsec-demo.pcap
KEYS=/tmp/radsec-keys.log
USER_NAME="${1:-jan}"
USER_PASS="${2:-jan123}"
SECRET="${RADIUS_SECRET:-testing123}"

rm -f "$PCAP" "$KEYS"
tcpdump -i eth0 -U -n -w "$PCAP" 'udp port 1812 or tcp port 2083' >/dev/null 2>&1 &
TCPDUMP=$!
sleep 2

echo "### 1. RADIUS/UDP 1812 (klasycznie, bez TLS)"
radtest "$USER_NAME" "$USER_PASS" freeradius 0 "$SECRET" | grep -E 'Received|No reply'
sleep 1

echo "### 2. RadSec przez radsecproxy (kluczy nie da się wyciągnąć)"
radtest "$USER_NAME" "$USER_PASS" 127.0.0.1 0 "$SECRET" | grep -E 'Received|No reply'
sleep 1

echo "### 3. RadSec, poprawne hasło (klucze -> $KEYS)"
python3 /radsec/radsec_client.py "$USER_NAME" "$USER_PASS" --keylog "$KEYS"
sleep 1

echo "### 4. RadSec, złe hasło"
python3 /radsec/radsec_client.py "$USER_NAME" "zle_haslo" --keylog "$KEYS"
sleep 1

echo "### 5. Intruz z certyfikatem z obcego CA"
sleep 2 | openssl s_client -connect freeradius:2083 -CAfile "$PKI/ca.pem" \
    -cert "$PKI/rogue.pem" -key "$PKI/rogue.key" -keylogfile "$KEYS" -brief 2>&1 \
    | grep -E 'CONNECTION|error|alert' | head -3
sleep 1

kill "$TCPDUMP"; wait "$TCPDUMP" 2>/dev/null
echo
echo "Gotowe: $PCAP ($(wc -c < "$PCAP") B), klucze: $KEYS ($(wc -l < "$KEYS") linii)"
echo "Na hoście:"
echo "  docker compose cp client:$PCAP ."
echo "  docker compose cp client:$KEYS ."
