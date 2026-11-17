# AAA with RADIUS: środowisko Docker (Meeting #1, PoC)

FreeRADIUS 3.2 + MariaDB + panel daloRADIUS 2.4 w Docker Compose.
Baza startuje **bez użytkowników**: dodajemy ich z panelu w trakcie demo.

| Kontener | Rola | Adres |
|---|---|---|
| `db` | MariaDB: wspólna baza FreeRADIUS i daloRADIUS | 172.28.0.10 |
| `freeradius` | serwer AAA w trybie debug (`-X`) | 172.28.0.20, porty 1812/1813 udp |
| `daloradius` | panel WWW (Apache + PHP) | 172.28.0.30, http://localhost:8000 |
| `client` | „access point”: stąd wysyłamy `radtest` | 172.28.0.40 |

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

## Pliki

| Ścieżka | Rola |
|---|---|
| `docker-compose.yml` | kontenery, sieć, porty |
| `.env` | hasła do bazy i sekret RADIUS `testing123` |
| `freeradius/Dockerfile` | oficjalny obraz `freeradius-server:3.2.8` z naszymi plikami |
| `freeradius/raddb/mods-available/sql` | połączenie FreeRADIUS → MariaDB |
| `freeradius/raddb/clients.conf` | kto może wysyłać zapytania (sieć Dockera) |
| `db/init/01–03-*.sql` | schemat bazy FreeRADIUS + daloRADIUS (z repozytorium daloRADIUS) |
| `db/init/10-lab-seed.sql` | tylko wpis NAS dla kontenera `client` |

## Przydatne polecenia

```bash
docker compose exec db mariadb -uradius -pradpass_lab radius   # konsola SQL, np. SELECT * FROM radcheck;
docker compose restart freeradius                               # po dodaniu NAS w panelu
docker compose down                                             # stop (dane zostają)
docker compose down -v                                          # stop + pusta baza od nowa
```

## Typowe problemy

| Objaw | Rozwiązanie |
|---|---|
| `radtest` zwraca Access-Reject dla nowego użytkownika | Sprawdź w panelu, czy Password Type to `Cleartext-Password`, i czy nie ma literówki w haśle. |
| `Ignoring request … from unknown client` | Pakiet z adresu spoza `clients.conf`. Wysyłaj z kontenera `client`. |
| W panelu są stare użytkownicy (alice, bob) | Baza z poprzedniej wersji: `docker compose down -v && docker compose up -d`. |
| Ostrzeżenie `platform (linux/amd64) does not match` | Na Macu ARM to normalne, FreeRADIUS działa w emulacji. |
