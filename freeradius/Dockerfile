# FreeRADIUS 3.2 (oficjalny obraz projektu FreeRADIUS) + MariaDB (rlm_sql)
# https://hub.docker.com/r/freeradius/freeradius-server
FROM freeradius/freeradius-server:3.2.8

ENV DEBIAN_FRONTEND=noninteractive

# Narzędzia testowe w kontenerze:
#  - radtest/radclient są już w obrazie
#  - eapoltest (eapol_test z wpa_supplicant) -> Eksperyment 2 (PEAP / EAP-TLS)
#  - openssl -> własne CA i certyfikaty (Eksperyment 2 i 3)
RUN apt-get update \
 && apt-get install -y --no-install-recommends eapoltest openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# Nasze nadpisania konfiguracji (moduł SQL, klienci)
COPY raddb/ /etc/freeradius/

# Włączenie modułów / serwerów wirtualnych:
#  - sql    -> uwierzytelnianie i accounting z MariaDB
#  - status -> Status-Server na 127.0.0.1:18121 (healthcheck kontenera)
RUN ln -sf ../mods-available/sql   /etc/freeradius/mods-enabled/sql \
 && ln -sf ../sites-available/status /etc/freeradius/sites-enabled/status \
 && chgrp -R freerad /etc/freeradius \
 && chmod 0640 /etc/freeradius/mods-available/sql /etc/freeradius/clients.conf

EXPOSE 1812/udp 1813/udp

# Domyślnie tryb debug (-X): każdy pakiet widać w "docker compose logs -f freeradius".
# Entrypoint obrazu doda "freeradius" przed argumentem zaczynającym się od "-".
CMD ["-X"]
