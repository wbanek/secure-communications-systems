# FreeRADIUS 3.2 (oficjalny obraz projektu FreeRADIUS) + MariaDB (rlm_sql)
# https://hub.docker.com/r/freeradius/freeradius-server
FROM freeradius/freeradius-server:3.2.8

ENV DEBIAN_FRONTEND=noninteractive

# Narzędzia testowe w kontenerze:
#  - radtest/radclient są już w obrazie
#  - eapoltest (eapol_test z wpa_supplicant) -> Eksperyment 2 (PEAP / EAP-TLS)
#  - openssl -> własne CA i certyfikaty (Eksperyment 2 i 3), test RadSec (s_client)
#  - radsecproxy -> po stronie NAS-a (kontener client) zamienia RADIUS/UDP na RadSec
#  - tcpdump -> porównanie UDP/1812 (jawny tekst) z RadSec TCP/2083 (TLS)
#  - python3 -> radsec_client.py: klient RadSec zapisujący klucze TLS dla Wiresharka
RUN apt-get update \
 && apt-get install -y --no-install-recommends eapoltest openssl ca-certificates \
        radsecproxy tcpdump python3 \
 && rm -rf /var/lib/apt/lists/*

# Nasze nadpisania konfiguracji (moduł SQL, klienci)
COPY raddb/ /etc/freeradius/

# Włączenie modułów / serwerów wirtualnych:
#  - sql    -> uwierzytelnianie i accounting z MariaDB
#  - status -> Status-Server na 127.0.0.1:18121 (healthcheck kontenera)
#  - tls    -> RadSec (RADIUS over TLS) na TCP/2083
RUN ln -sf ../mods-available/sql   /etc/freeradius/mods-enabled/sql \
 && ln -sf ../sites-available/status /etc/freeradius/sites-enabled/status \
 && ln -sf ../sites-available/tls    /etc/freeradius/sites-enabled/tls \
 && mkdir -p /etc/freeradius/certs/radsec \
 && chgrp -R freerad /etc/freeradius \
 && chmod 0640 /etc/freeradius/mods-available/sql /etc/freeradius/clients.conf

EXPOSE 1812/udp 1813/udp 2083/tcp

# Tryb debug: każdy pakiet widać w "docker compose logs -f freeradius".
# UWAGA: nie "-X"! -X = jednowątkowy debug, a FreeRADIUS odmawia wtedy
# otwarcia gniazd TLS ("Threading must be enabled for TLS sockets").
# "-fxx -l stdout" daje ten sam poziom logów, ale z wątkami -> RadSec działa.
# Entrypoint obrazu doda "freeradius" przed argumentem zaczynającym się od "-".
CMD ["-fxx", "-l", "stdout"]
