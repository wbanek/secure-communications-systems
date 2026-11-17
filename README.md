# AAA with RADIUS: środowisko Docker (Meeting #1, PoC)

FreeRADIUS 3.2 + MariaDB + panel daloRADIUS 2.4 w Docker Compose,
plus **RadSec (RADIUS over TLS, RFC 6614)** między „access pointem” a serwerem.
Baza startuje **bez użytkowników**: dodajemy ich z panelu w trakcie demo.

| Kontener | Rola | Adres |
|---|---|---|
| `db` | MariaDB: wspólna baza FreeRADIUS i daloRADIUS | 172.28.0.10 |
| `freeradius` | serwer AAA w trybie debug (`-fxx`) | 172.28.0.20, porty 1812/1813 udp, **2083 tcp (RadSec)** |
| `daloradius` | panel WWW (Apache + PHP) | 172.28.0.30, http://localhost:8000 |
| `client` | „access point”: stąd wysyłamy `radtest`; działa na nim `radsecproxy` | 172.28.0.40 |
| `pki` | jednorazowo generuje CA i certyfikaty RadSec, potem się kończy (`exited (0)`) | brak sieci |

## Start

```bash
cd aaa-radius-docker
docker compose down -v          # tylko jeśli stawiałeś wcześniejszą wersję (czyści starą bazę)
docker compose up -d --build    # pierwszy build: kilka minut
docker compose ps               # wszystko "running" / "healthy"
```

Panel: **http://localhost:8000**, login `administrator`, hasło `radius`.

## Scenariusz demo (ok. 5 minut)

Przygotuj trzy okna obok siebie.

**Okno 1: logi serwera na żywo**
```bash
docker compose logs -f --tail=0 freeradius
```

**Okno 2: panel daloRADIUS**
1. *Management → Users → New User*.
2. Zakładka *Account Info*: Username `jan`, Password `jan123`, Password Type **Cleartext-Password** (domyślny).
3. Opcjonalnie zakładka *User Info*: imię i nazwisko.
4. *Apply* daje komunikat o powodzeniu. Użytkownik jest teraz w tabeli `radcheck`.

**Okno 3: zapytanie od klienta**
```bash
docker compose exec client radtest jan jan123 freeradius 0 testing123
```
Wynik: `Received Access-Accept`. Serwera **nie trzeba restartować**, bo FreeRADIUS pyta bazę przy każdym żądaniu.

W oknie 1 pokaż po kolei:
1. `Received Access-Request … from 172.28.0.40`: pakiet od klienta.
2. `SELECT … FROM radcheck WHERE username = 'jan'` i `User found in radcheck table`: serwer znalazł użytkownika dodanego przed chwilą w panelu.
3. `Auth-Type PAP` i `User authenticated successfully`: hasło się zgadza.
4. `INSERT INTO radpostauth …`: zapis próby logowania.
5. `Sent Access-Accept`: odpowiedź.

Kontrast, czyli złe hasło:
```bash
docker compose exec client radtest jan zle freeradius 0 testing123
```
W logu pojawi się `pap: Passwords don't match` i `Sent Access-Reject`.

Na koniec w panelu: *Reports → Last Connection Attempts* pokazuje obie próby (Accept i Reject).

## RadSec: RADIUS over TLS (ok. 5 minut)

Klasyczny RADIUS to UDP z „zabezpieczeniem” opartym na MD5 i wspólnym sekrecie:
nazwa użytkownika, adres NAS, atrybuty accountingu idą jawnym tekstem, a hasło
jest tylko zaciemnione (XOR z MD5 sekretu). RadSec przenosi te same pakiety
RADIUS do tunelu **TLS 1.3 po TCP/2083** z **wzajemnym uwierzytelnieniem certyfikatami**.

```
 kontener client (NAS)                                    kontener freeradius
 ┌────────────────────────────────────┐                  ┌──────────────────────┐
 │ radtest ──UDP──▶ radsecproxy       │ ══ TLS 1.3 ════▶ │ listen tcp/2083 (tls) │
 │        127.0.0.1:1812   (cert NAS) │   TCP/2083       │ → serwer "default"    │
 └────────────────────────────────────┘                  │ → SQL (daloRADIUS)    │
                                                         └──────────────────────┘
```

UDP z `radtest` nie wychodzi poza kontener `client`; na kablu jest wyłącznie TLS.
Sekret w RadSec to stała `radsec` (RFC 6614): bezpieczeństwo daje TLS, nie MD5.

**Okno 1:** logi serwera `docker compose logs -f --tail=0 freeradius`
**Okno 2:** logi proxy po stronie NAS `docker compose logs -f client`

**1. Logowanie przez RadSec** (użytkownik `jan` dodany wcześniej w panelu):
```bash
docker compose exec client radtest jan jan123 127.0.0.1 0 testing123
```
Wynik: `Received Access-Accept`. Uwaga: adresem jest `127.0.0.1` (radsecproxy), a nie `freeradius`.

W oknie 2 (radsecproxy):
```
tlsconnect: TLS connection to freeradius (freeradius port 2083), subject CN=freeradius,O=AAA Lab, TLSv1.3 with cipher TLS_AES_256_GCM_SHA384 up
Access-Accept for user jan from freeradius to localhost (127.0.0.1)
```
W oknie 1 (FreeRADIUS) pokaż:
1. `Listening on auth+acct from client (172.28.0.40, …) -> (*, 2083, …)`: nowe połączenie TCP.
2. `(TLS) RADIUS/TLS - recv TLS 1.3 Handshake, ClientHello` … `send … CertificateRequest`: serwer żąda certyfikatu klienta.
3. `TLS-Client-Cert-Common-Name := "nas-client"` i `TLS-Client-Cert-Issuer := "/O=AAA Lab/CN=AAA Lab RadSec CA"`: kim jest NAS, według certyfikatu.
4. `TLS-Session-Version = "TLS 1.3"`, `TLS-Session-Cipher-Suite = "TLS_AES_256_GCM_SHA384"`.
5. `Received Access-Request … to 0.0.0.0:2083`, dalej to samo co przy UDP: SQL, `radcheck`, PAP, `Sent Access-Accept`.

Kolejne `radtest` wysłane w ciągu 30 s używają **tego samego** połączenia TLS, bez nowego handshake'u (`idle_timeout = 30` w `sites-available/tls`). Accounting też idzie tym tunelem:
```bash
docker compose exec client sh -c 'echo "Acct-Status-Type = Start, User-Name = jan, Acct-Session-Id = demo1, NAS-IP-Address = 172.28.0.40" | radclient 127.0.0.1 acct testing123'
```
W oknie 1 widać `Accounting-Request` odebrany na porcie 2083 i `INSERT INTO radacct`, a w panelu *Accounting* pojawia się sesja użytkownika `jan`.

**2. Co widać na kablu: UDP kontra RadSec.** W trzecim oknie:
```bash
docker compose exec client tcpdump -i eth0 -n -A 'udp port 1812 or tcp port 2083'
```
Najpierw zwykły RADIUS po UDP, potem RadSec:
```bash
docker compose exec client radtest jan jan123 freeradius 0 testing123   # UDP/1812
docker compose exec client radtest jan jan123 127.0.0.1  0 testing123   # RadSec
```
Przy UDP w zrzucie widać jawnie `jan`, a przy RadSec wyłącznie zaszyfrowane rekordy TLS na porcie 2083.

**3. Bez certyfikatu nie ma rozmowy.** Wzajemne TLS: serwer odrzuca klienta bez certyfikatu albo z certyfikatem z obcego CA:
```bash
# bez certyfikatu klienta
docker compose exec client sh -c 'sleep 2 | openssl s_client -connect freeradius:2083 -CAfile /etc/radsecproxy/pki/ca.pem -brief'
# certyfikat z obcego CA ("intruz")
docker compose exec client sh -c 'sleep 2 | openssl s_client -connect freeradius:2083 -CAfile /etc/radsecproxy/pki/ca.pem -cert /etc/radsecproxy/pki/rogue.pem -key /etc/radsecproxy/pki/rogue.key -brief'
```
Klient zobaczy `unexpected eof`, bo serwer zrywa połączenie. W TLS 1.3 klient najpierw wypisuje `CONNECTION ESTABLISHED`, a certyfikat klienta jest sprawdzany chwilę później. Powód odrzucenia jest w oknie 1:
- bez certyfikatu: `peer did not return a certificate`,
- obce CA: `unable to get local issuer certificate` i `Alert write:fatal:unknown CA`.

Przy obu próbach w logu **nie ma ani jednego** `Access-Request`, więc atakujący nie dociera nawet do warstwy RADIUS.

**4. Sprawdzenie serwera i jego certyfikatu** (to, co weryfikuje radsecproxy, `certificateNameCheck on`):
```bash
docker compose exec client openssl s_client -connect freeradius:2083 -CAfile /etc/radsecproxy/pki/ca.pem -cert /etc/radsecproxy/pki/client.pem -key /etc/radsecproxy/pki/client.key -verify_hostname freeradius -brief </dev/null
```
`Protocol version: TLSv1.3`, `Peer certificate: O = AAA Lab, CN = freeradius`, `Verification: OK`.

## RadSec w Wiresharku (najlepsze do prezentacji)

Jeden skrypt nagrywa na kontenerze `client` pięć scen: UDP, RadSec przez radsecproxy, RadSec z poprawnym hasłem, RadSec ze złym hasłem i „intruza”. Przy okazji zapisuje **klucze sesji TLS** (plik w formacie SSLKEYLOGFILE), dzięki którym Wireshark może odszyfrować tunel:

```bash
docker compose exec client sh /radsec/wireshark-demo.sh
docker compose cp client:/tmp/radsec-demo.pcap .
docker compose cp client:/tmp/radsec-keys.log .
```
Otwórz `radsec-demo.pcap` w Wiresharku, filtr: `radius || tls`.

**Screen 1. Klasyczny RADIUS/UDP: wszystko na wierzchu.**
Kliknij `Access-Request` na porcie 1812. W drzewie widać `User-Name: jan`, `NAS-IP-Address` i resztę atrybutów jawnym tekstem.
Następnie *Edit → Preferences → Protocols → RADIUS → Shared Secret* = `testing123`. Wireshark pokaże wtedy **`User-Password: jan123`**.
Teza: kto zna (albo złamie słownikiem) sekret i ma nagrany ruch, odczyta hasła wszystkich użytkowników.

**Screen 2. RadSec bez kluczy: nic nie widać.**
Te same logowania na porcie 2083 to `Client Hello`, `Server Hello` i dalej tylko `Application Data`. Nie widać nazwy użytkownika ani hasła, a od TLS 1.3 nawet certyfikaty są zaszyfrowane.
Sekret RadSec (`radsec`) jest publiczny, a mimo to podsłuch nic nie daje.

**Screen 3. RadSec z kluczami: dowód, że w tunelu jest RADIUS.**
*Edit → Preferences → Protocols → TLS → (Pre)-Master-Secret log filename* = `radsec-keys.log`.
- Handshake rozwija się w `Encrypted Extensions, Certificate Request, Certificate, Certificate Verify, Finished`. W ramce `Certificate` od klienta widać `CN=nas-client`, a od serwera `CN=freeradius`. To jest wzajemne uwierzytelnienie.
- Kliknij `Application Data` (ok. 175 B) i w dolnym panelu wybierz zakładkę **Decrypted TLS**. Pierwszy bajt `01` oznacza Access-Request, dalej widać `jan` i `radsec-demo-client`. W odpowiedzi pierwszy bajt to `02` (Accept) albo `03` (Reject).
- Albo: prawy klik → *Follow → TLS Stream*.
- Jeśli Twoja wersja Wiresharka ma w *Decode As…* dla „TLS port” 2083 protokół RADIUS, wybierz go, a dostaniesz pełne drzewo atrybutów (w 4.2 tej opcji nie ma).

Teza: odczytać tunel może tylko ktoś, kto ma klucze sesji, czyli jedna ze stron połączenia. Ruchu radsecproxy (scena 2) nie da się odszyfrować, bo radsecproxy kluczy nie zapisuje.

**Screen 4. Intruz.** Ostatnie połączenie: w ramce `Certificate` od klienta jest `CN=rogue-nas`, wystawca `Rogue CA`. Zaraz po nim pojawia się fatalny `Alert` i koniec połączenia. Nie ma ani jednej ramki z danymi RADIUS. W logu FreeRADIUS widać przyczynę: `send TLS 1.3 Alert, fatal unknown_ca`.

> `radsec/radsec_client.py` to minimalny klient RadSec (Python, bez zależności). Wysyła Access-Request przez TLS i zapisuje klucze sesji. Można go używać osobno: `docker compose exec client python3 /radsec/radsec_client.py jan jan123`.

## Pliki

| Ścieżka | Rola |
|---|---|
| `docker-compose.yml` | kontenery, sieć, porty |
| `.env` | hasła do bazy i sekret RADIUS `testing123` |
| `freeradius/Dockerfile` | oficjalny obraz `freeradius-server:3.2.8` z naszymi plikami |
| `freeradius/raddb/mods-available/sql` | połączenie FreeRADIUS → MariaDB |
| `freeradius/raddb/clients.conf` | kto może wysyłać zapytania (sieć Dockera) |
| `freeradius/raddb/sites-available/tls` | RadSec: nasłuch TCP/2083, TLS 1.2–1.3, wymagany certyfikat klienta, lista klientów RadSec |
| `radsec/gen-certs.sh` | generuje Lab RadSec CA (ECDSA P-256), certyfikat serwera, NAS-a i „intruza” z obcego CA |
| `radsec/radsecproxy.conf` | NAS: przyjmuje UDP na 127.0.0.1:1812/1813, wysyła RadSec do `freeradius:2083` |
| `radsec/radsec_client.py` | minimalny klient RadSec zapisujący klucze TLS (do odszyfrowania w Wiresharku) |
| `radsec/wireshark-demo.sh` | nagrywa `radsec-demo.pcap` + `radsec-keys.log`: UDP, RadSec, złe hasło, intruz |
| `db/init/01–03-*.sql` | schemat bazy FreeRADIUS + daloRADIUS (z repozytorium daloRADIUS) |
| `db/init/10-lab-seed.sql` | tylko wpis NAS dla kontenera `client` |

## Przydatne polecenia

```bash
docker compose exec db mariadb -uradius -pradpass_lab radius   # konsola SQL, np. SELECT * FROM radcheck;
docker compose restart freeradius                               # po dodaniu NAS w panelu
docker compose down                                             # stop (dane zostają)
docker compose down -v                                          # stop + pusta baza od nowa (i nowe certyfikaty RadSec)
docker compose logs pki                                         # jakie certyfikaty wygenerowano
docker compose exec client openssl x509 -in /etc/radsecproxy/pki/client.pem -noout -text   # podgląd certyfikatu NAS-a
```

## Typowe problemy

| Objaw | Rozwiązanie |
|---|---|
| `radtest` zwraca Access-Reject dla nowego użytkownika | Sprawdź w panelu, czy Password Type to `Cleartext-Password`, i czy nie ma literówki w haśle. |
| `Ignoring request … from unknown client` | Pakiet z adresu spoza `clients.conf`. Wysyłaj z kontenera `client`. |
| W panelu są stare użytkownicy (alice, bob) | Baza z poprzedniej wersji: `docker compose down -v && docker compose up -d`. |
| Ostrzeżenie `platform (linux/amd64) does not match` | Na Macu ARM to normalne, FreeRADIUS działa w emulacji. |
| `Threading must be enabled for TLS sockets to function properly` | FreeRADIUS uruchomiony z `-X`. RadSec wymaga wątków: używamy `-fxx -l stdout` (ten sam poziom logów). |
| `radtest … 127.0.0.1` daje `No reply from server` | radsecproxy nie zestawił TLS: `docker compose logs client`. Najczęściej brak certyfikatów (`docker compose logs pki`) albo serwer jeszcze nie wstał. |
| `pki` kończy się błędem `sh: …\r: not found` | Windows zamienił końce linii na CRLF. Repo ma `.gitattributes` (LF), więc sklonuj je ponownie albo `git add --renormalize .`. |
| W logu serwera `Certificate chain - 1 intermediate CA cert(s) untrusted` | Informacja, nie błąd: radsecproxy dosyła CA w łańcuchu. Weryfikacja i tak idzie względem `ca.pem`. |
