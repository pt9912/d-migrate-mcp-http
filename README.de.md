# d-migrate MCP (HTTP)

[English](README.md) | **Deutsch**

## Was ist d-migrate MCP (HTTP)?

Ein lokales Docker-Compose-Setup, das den
[d-migrate](https://github.com/pt9912/d-migrate)-MCP-Server (HTTP-Transport)
gegen echte Postgres-, SQL-Server-, MySQL- und SQLite/SpatiaLite-Test-
datenbanken betreibt — d-migrates vier unterstützte Dialekte — und
project-scoped in Claude Code registriert (`.mcp.json`). Für alle, die
d-migrates
Schema-/Daten-Tools als MCP-Tools aus einer Claude-Code-Session heraus
aufrufen wollen, ohne d-migrate manuell zu bauen, zu installieren oder
Connections/State von Hand zu verdrahten.

## Was kann ich heute tun?

- `make up` startet die Test-Datenbanken und den MCP-Server; danach läuft
  er unter `http://127.0.0.1:8787/mcp`.
- Nach einmaliger Freigabe des project-scoped `.mcp.json`-Servers in
  Claude Code stehen 24 Tools zur Verfügung (`schema_validate`,
  `schema_reverse_start`, `data_profile_start`, `job_status_get`, …).
- `schema_reverse_start` gegen jede der fuenf verdrahteten Connections
  (`local_pg`, `local_mssql`, `local_mysql`, `local_sqlite`,
  `local_oracle`) liefert
  `SUCCEEDED` mit Artefakt — bei allen fuenfen per Tool-Call verifiziert.
- Ein laufender Job übersteht `docker compose restart d-migrate-mcp` —
  Server-State liegt in Postgres, nicht in-memory; verifiziert (Job vor
  Neustart erzeugt, `job_status_get` liefert danach denselben Status).
- `policy-rules.yaml` lässt read-only/planende `*_start`-Tools durch;
  schreibende Tools bleiben ohne Freigabe blockiert (`policy:no-rule`
  ohne Regel, `challenge` mit Regel) — beides mit echten Tool-Calls
  gegengeprüft.

## Warum d-migrate MCP (HTTP)?

Der MCP-Server allein (ohne Connection-Config, Policy-File, Server-State)
lässt sich zwar in Sekunden starten, kann dann aber nur gegen
Schema-Dateien arbeiten — jedes Tool, das eine echte Datenbank anfasst,
läuft ins Leere (keine registrierte Connection) oder wird von der
Fail-closed-Policy abgelehnt. Die Alternative wäre, das bei jedem Bedarf
von Hand zu verdrahten. Dieses Repo bündelt das minimal Nötige einmal,
lokal und ohne die volle Auth-Infrastruktur (`jwt-jwks`), die nur für
Nicht-Loopback-Betrieb gebraucht wird.

## Kerngedanke

So wenig Konfiguration wie möglich, aber genug, um echte DB-Tools nutzbar
zu machen: jede zusätzliche Datei oder jeder zusätzliche Service
(`.d-migrate.yaml`, `policy-rules.yaml`, die Postgres-/SQL-Server-/
MySQL-Container) existiert nur, weil ein konkretes Tool sie sonst nicht
ausführen könnte — nicht auf Vorrat.

## Was macht es vertrauenswürdig?

- **Auth-Grenze:** `--auth-mode disabled` ist serverseitig strikt auf
  Loopback beschränkt (Boot-Validierung lehnt Nicht-Loopback-Bind ab,
  kein stiller Fallback) — [Administrationshandbuch §9.1](https://github.com/pt9912/d-migrate/blob/main/docs/user/administrationshandbuch.md#9-sicherheit).
- **Policy:** ohne passende Regel in `policy-rules.yaml` ist jeder
  `*_start`-Job standardmäßig `Deny` (`policy:no-rule`), fail-closed —
  [Administrationshandbuch §6.7](https://github.com/pt9912/d-migrate/blob/main/docs/user/administrationshandbuch.md#67-policy-gesteuerte-datenoperationen).
- **Persistenz:** Server-State liegt im Postgres-Schema `dmigrate_state`
  (Flyway-migriert), nicht in-memory — durch Job-Überleben nach
  Container-Neustart verifiziert, nicht nur behauptet.
- **Kanonische Quellen:** [Anwenderhandbuch](https://github.com/pt9912/d-migrate/blob/main/docs/user/anwenderhandbuch.md),
  [Administrationshandbuch](https://github.com/pt9912/d-migrate/blob/main/docs/user/administrationshandbuch.md),
  [MCP server spec](https://github.com/pt9912/d-migrate/blob/main/spec/mcp-server.md)
  im d-migrate-Repo — dieses README verweist darauf, dupliziert sie nicht.

---

- **Host-Voraussetzungen:** nur `docker` (mit Compose v2), `jq` und `curl`.
  Alles andere laeuft *in Images* — die DB-Clients und `sqlite3` in den
  Compose-Containern und in `tools/harness-tools`, der Python-Typcheck der
  Matrix in der `py`-Stage derselben Dockerfile. Kein Host-Python, kein
  Host-DB-Client, und nichts wird ausserhalb des Repos geschrieben.

## Setup (nach dem Klonen)

1. **Docker + Docker Compose v2** nötig. `network_mode: host` (damit der
   Container auf Loopback binden und trotzdem vom Host erreichbar sein
   kann) ist **Linux-only** — funktioniert so nicht unter macOS/Windows
   Docker Desktop.
2. Ports müssen frei sein: `8787` (MCP), `5433` (Postgres, siehe
   `PG_PORT`), `1433` (SQL Server, siehe `MSSQL_PORT`), `3306` (MySQL,
   siehe `MYSQL_PORT`) und `1521` (Oracle, siehe `ORACLE_PORT`) in
   `.env` — bei Kollision anpassen. SQLite hat keinen Port, es ist eine
   Datei unter `./sqlite-data`.
3. `cp .env.example .env` und echte Passwörter setzen — `POSTGRES_PASSWORD`,
   `MSSQL_SA_PASSWORD`, `MYSQL_ROOT_PASSWORD` und `ORACLE_PASSWORD`
   müssen jeweils synchron zum Passwort in der passenden
   `D_MIGRATE_LOCAL_*_URL` bleiben (gleiche Datei, je zwei Stellen, keine
   Variablen-Interpolation dazwischen).
   `MSSQL_SA_PASSWORD` muss die SQL-Server-Komplexitätsregel erfüllen
   (mind. 8 Zeichen, 3 von 4 Kategorien); alle vier DB-Passwörter sollten
   URL-reservierte Zeichen (`@ : / ? # %`) vermeiden, damit sie in der URL
   nicht percent-encoded werden müssen. `.env` ist gitignored, wird nie
   committet.
4. `make up` — zieht `ghcr.io/pt9912/d-migrate:1.7.1`,
   `postgis/postgis:18-3.6` (PostgreSQL 18 + PostGIS 3.6, digest-gepinnt),
   `mcr.microsoft.com/mssql/server:2022-latest`,
   `mysql:8.4` und `gvenzl/oracle-free:23-faststart`, startet sie,
   wartet auf „healthy“, führt einmalig `mssql-init` aus (legt die
   Datenbank `dmigrate` an — SQL Servers Default-Datenbank `master` wird
   bewusst nicht als Ziel genutzt; MySQL legt seine `dmigrate`-Datenbank
   selbst per `MYSQL_DATABASE` an; der Oracle-App-User `dmigrate` entsteht
   beim ersten Start des `oracle`-Service), dann den MCP-Server
   (registriert `local_pg`, `local_mssql`, `local_mysql`, `local_sqlite`,
   `local_oracle`, migriert das `dmigrate_state`-Schema). Der erste
   Oracle-Start braucht einige Minuten.
5. Projekt in Claude Code öffnen. `.mcp.json` ist eingecheckt, aber
   **standardmäßig nicht vertraut** — Claude Code zeigt `d-migrate` als
   „⏸ Pending approval“, bis einmal bestätigt wird (`claude mcp list` /
   `/mcp`-Prompt). Neue Tools erscheinen erst in einer danach frisch
   gestarteten Session.
6. `./state` (dateibasierte MCP-Artefakte), `./sqlite-data` (die
   SQLite-Datei, wird bei Bedarf angelegt) und die Docker-Volumes
   (`pg-data`, `mssql-data`, `mysql-data`, `oracle-data`) entstehen beim
   ersten Start, sind gitignored und lokal — ein frischer Clone startet
   mit leerem State.

## How it's wired

- **Auth**: `--auth-mode disabled`, strikt Loopback-only (`127.0.0.1`).
- **MCP-State-Dir**: `./state`, in den Container gemountet, Host-User-Owned
  (`.env` setzt `UID`/`GID`) — dateibasierte Upload-Segmente/Artefakte.
- **DB-Connections** (alle `.d-migrate.yaml`, Tenant `default`): lokales
  Postgres (`postgis/postgis:18-3.6`, `127.0.0.1:${PG_PORT:-5433}`) als
  `local_pg`; lokaler SQL Server
  (`mcr.microsoft.com/mssql/server:2022-latest`,
  `127.0.0.1:${MSSQL_PORT:-1433}`, Datenbank `dmigrate`) als
  `local_mssql`; lokales MySQL (`mysql:8.4`,
  `127.0.0.1:${MYSQL_PORT:-3306}`, Datenbank `dmigrate`) als
  `local_mysql`; eine SQLite-Datei unter `./sqlite-data/local.db` (wird
  bei Bedarf angelegt, `?spatialite=true` lädt das im
  d-migrate-Runtime-Image bereits enthaltene `mod_spatialite`) als
  `local_sqlite`; lokales Oracle
  (`gvenzl/oracle-free:23-faststart`, `127.0.0.1:${ORACLE_PORT:-1521}`,
  FREEPDB1, App-User `dmigrate`) als `local_oracle` (der erste Start legt
  den User an und braucht einige Minuten; Bereitschaft wird ueber das
  `healthcheck.sh` des Images gepollt).
- **Server-State**: Jobs/Quotas/Idempotency/Schema-Stores JDBC-backed im
  selben Postgres, Schema `dmigrate_state` (`server.state` in
  `.d-migrate.yaml`, `migrations.auto: true`).
- **Policy**: `policy-rules.yaml` erlaubt read-only/planende `*_start`-Tools
  für Tenant `default`; Schreib-Tools (`data_import_start`,
  `data_transfer_start`, `testdata_execute`,
  `procedure_transform_execute`) verlangen eine Freigabe
  (`mcp approval-grant issue`).

## Usage

```bash
make up        # start (test databases, then d-migrate-mcp)
make down      # stop
make down-v    # stop and drop ALL db volumes (pg/mssql/mysql/oracle)
make smoke     # round-trip smoke test (see below)
make logs      # tail logs
make restart   # restart d-migrate-mcp — pick up .d-migrate.yaml / policy-rules.yaml edits
```

## Round-Trip-Smoke-Test

`make smoke` faehrt einen vollstaendigen Cross-Dialect-Round-Trip gegen den
laufenden Stack (siehe `scripts/roundtrip-smoke.sh`): `local_pg` wird aus
einem festen Repro-Schema geseedet (CHECK-Constraints, computed column,
UNIQUE auf ungebundenem TEXT, FKs mit RESTRICT/NO ACTION, Enum-Typ, View,
dazu eine Typ-Tabelle mit json/jsonb, interval, uuid, xml, bytea, char,
smallint, real und Arrays sowie nullable PostGIS-Geometrie),
alle fuenf Connections werden zurueckgelesen, DDL in alle fuenf Dialekte
generiert, mit den nativen Clients angewendet (sqlcmd/mysql/sqlite3/sqlplus
— die MCP-Tools kennen kein "DDL anwenden"), wieder zurueckgelesen und
verglichen. Geprueft werden die versionsgebundene Erwartungsmatrix in
`scripts/roundtrip-expectations.env` (`GEN_*` = status/skippedCount von
`schema_generate`, `COMPARE_*` = Finding-Zahl gegen das PG-Reverse) plus die
versionsunabhaengige Regel, dass kein unveraenderter FK als Compare-Finding
erscheint.

Der SQLite-Leg laeuft im kleinen Werkzeug-Image `tools/harness-tools`
(`make harness-tools`; sqlite3 + mod_spatialite); der Python-Typcheck der
Matrix nutzt die Stage `py` derselben Datei (`make harness-tools` baut
beide) — der Host hat keine
SpatiaLite-Extension, das d-migrate-Runtime-Image keinen sqlite3-CLI. Der
Smoke baut es bei Bedarf selbst.

Aendert eine neue d-migrate-Version die Zahlen legitim (z. B. hebt der
upstream-Fix fuer Oracles Skipped-Object-Unterzaehlung
`GEN_ORACLE_SKIPPED` von 3 auf 5), den Diff bewusst pruefen und neu pinnen
mit `make smoke UPDATE=--update-expectations` — nach Pruefung, nicht blind.

```bash
make smoke                                  # Lauf gegen Erwartungen
make smoke UPDATE=--update-expectations     # nach gepruefter Aenderung neu pinnen
```

## Typ-Matrix

`make type-matrix` ist eine eigene, breitere Sonde: jeder Dialekt bekommt ein
Seed mit seinen *nativen* Typen (`scripts/types/*.sql` — inklusive
Dialekt-Eigenheiten wie `sql_variant`, `rowversion`, `money`,
`year`/`set`/`enum`, `XMLTYPE`, `ROWID`, `SDO_GEOMETRY`,
SpatiaLite-Geometrien); dieses Schema wird zurueckgelesen, in alle vier
anderen Dialekte generiert, dort angewendet, wieder zurueckgelesen und
verglichen. Ausgabe ist eine 5x5-Finding-Matrix plus die Finding-Codes je
Zelle — das systematische Gegenstueck zum festen Repro des Smoke.

Sie leert waehrend des Laufs die vier Testdatenbanken (ein Reverse traegt die
ganze Schemaflaeche, Reste wuerden beim Anwenden kollidieren) und laesst sie
leer; der naechste `make smoke` baut alles neu auf. Die SQLite-Legs laufen im
selben Werkzeug-Image wie der Smoke.

```bash
make type-matrix                # 5x5-Lauf, raeumt danach auf
make type-matrix KEEP=--keep    # angewendete Tabellen stehen lassen
```

Ein Latenz-Benchmark gegen den MCP-Server liegt in
`scripts/mcp-bench.sh` (`--restart` misst zusaetzlich den Kaltstart;
nuetzlich zum Vergleichen von JVM- und Native-Image).

## Docs

- [Anwenderhandbuch](https://github.com/pt9912/d-migrate/blob/main/docs/user/anwenderhandbuch.md)
- [Administrationshandbuch](https://github.com/pt9912/d-migrate/blob/main/docs/user/administrationshandbuch.md)
- [MCP server spec](https://github.com/pt9912/d-migrate/blob/main/spec/mcp-server.md)

## Bestehenden Checkout aktualisieren

Zwei Stack-Aenderungen sind **nicht** drop-in fuer ein vorhandenes
`pg-data`-Volume:

- Das Postgres-Image wechselte von `postgres:17.10-trixie` auf
  `postgis/postgis:18-3.6` (ein **Major**-Sprung). PostgreSQL startet nicht
  auf einem Datenverzeichnis einer aelteren Major-Version; der Container
  restart-loopt und `make up` wird nie healthy. Deshalb zuerst das Volume
  neu anlegen: `make down-v` (loescht **alle vier** DB-Volumes — `pg-data`,
  `mssql-data`, `mysql-data`, `oracle-data`; die Testdatenbanken werden beim
  naechsten Lauf aus den Seeds wieder aufgebaut).
- PG 18 erwartet das Volume unter `/var/lib/postgresql` (ohne `/data`); die
  Compose-Datei mountet es bereits dort.

Bei bereits laufendem Volume also: `make down-v && make up`. PostGIS und der
`search_path`-Eintrag entstehen durch `postgres-init/01-postgis.sh`, das der
Postgres-Entrypoint nur bei einem **frischen** Volume ausfuehrt — bei
bestehendem Volume von Hand anlegen oder Volume neu erstellen (Smoke und
Typ-Matrix pruefen die Geometrie-Metadaten inzwischen und scheitern laut,
wenn sie fehlen).

## Upgrading

Bump the image tag in `docker-compose.yml` (pinned to `1.7.1`), then
`make up`.

For production/multi-host use, switch `--auth-mode` to `jwt-jwks` (see
spec §6.2) instead of binding non-loopback with auth disabled.
