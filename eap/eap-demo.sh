#!/bin/sh
# ============================================================================
#  Demo metod EAP (802.1X) na kontenerze client, z nagraniem do Wiresharka
#
#    docker compose exec client sh /eap/eap-demo.sh
#    docker compose cp client:/tmp/eap-demo.pcap .
#
#  Każda metoda jest testowana dwa razy:
#    UDP    - eapol_test -> freeradius:1812  (EAP w RADIUS/UDP, widoczny w pcap)
#    RadSec - eapol_test -> radsecproxy 127.0.0.1:1812 -> TLS -> freeradius:2083
# ============================================================================
set -u
PCAP=/tmp/eap-demo.pcap
SECRET="${RADIUS_SECRET:-testing123}"
SERVER_IP=172.28.0.20

run() {   # $1 = plik konfiguracji, $2 = adres serwera RADIUS, $3 = opis
    res=$(eapol_test -c "/eap/$1.conf" -a "$2" -s "$SECRET" -t 15 2>&1)
    tls=$(echo "$res" | grep -o 'Using TLS version TLSv1\.[0-9]' | head -1 | sed 's/.* //')
    out=$(echo "$res" | grep -E '^(SUCCESS|FAILURE)' | tail -1)
    printf "  %-22s %-7s %-8s %s\n" "$1" "$3" "${tls:--}" "${out:-FAILURE (brak odpowiedzi)}"
}

rm -f "$PCAP"
tcpdump -i eth0 -U -n -s 0 -w "$PCAP" 'udp port 1812 or tcp port 2083' >/dev/null 2>&1 &
TCPDUMP=$!
sleep 2

printf "  %-22s %-7s %-8s %s\n" "METODA" "DROGA" "TLS" "WYNIK"
for m in peap-mschapv2 ttls-pap eap-tls eap-tls-podszycie; do
    run "$m" "$SERVER_IP" "UDP"
    run "$m" "127.0.0.1"  "RadSec"
done

sleep 1
kill "$TCPDUMP"; wait "$TCPDUMP" 2>/dev/null
echo
echo "Oczekiwane: SUCCESS dla trzech pierwszych metod, FAILURE dla eap-tls-podszycie."
echo "Nagranie: $PCAP  ->  docker compose cp client:$PCAP ."
