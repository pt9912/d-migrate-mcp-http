# d-migrate MCP (HTTP)

[English](README.md) | **Deutsch**

## Was ist d-migrate MCP (HTTP)?

Ein lokales Docker-Compose-Setup, das den
[d-migrate](https://github.com/pt9912/d-migrate)-MCP-Server (HTTP-Transport)
gegen eine echte Postgres-Testdatenbank betreibt und project-scoped in
Claude Code registriert (`.mcp.json`). Für alle, die d-migrates
Schema-/Daten-Tools als MCP-Tools aus einer Claude-Code-Session heraus
aufrufen wollen, ohne d-migrate manuell zu bauen, zu installieren oder
Connections/State von Hand zu verdrahten.

## Was kann ich heute tun?

- `make up` startet Postgres und den MCP-Server; danach läuft er unter
  `http://127.0.0.1:8787/mcp`.
- Nach einmaliger Freigabe des project-scoped `.mcp.json`-Servers in
  Claude Code stehen 22 Tools zur Verfügung (`schema_validate`,
  `schema_reverse_start`, `data_profile_start`, `job_status_get`, …).
- `schema_reverse_start` gegen die verdrahtete Connection `local_pg`
  liefert `SUCCEEDED` mit Artefakt — verifiziert per Tool-Call.
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
zu machen: jede zusätzliche Datei (`.d-migrate.yaml`, `policy-rules.yaml`,
Postgres-Service) existiert nur, weil ein konkretes Tool sie sonst nicht
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

## Setup (nach dem Klonen)

1. **Docker + Docker Compose v2** nötig. `network_mode: host` (damit der
   Container auf Loopback binden und trotzdem vom Host erreichbar sein
   kann) ist **Linux-only** — funktioniert so nicht unter macOS/Windows
   Docker Desktop.
2. Ports müssen frei sein: `8787` (MCP) und `5433` (Postgres, siehe
   `PG_PORT` in `.env` — bei Kollision anpassen).
3. `cp .env.example .env` und ein echtes `POSTGRES_PASSWORD` setzen — muss
   synchron zum Passwort in `D_MIGRATE_LOCAL_PG_URL` bleiben (gleiche
   Datei, zwei Stellen, keine Variablen-Interpolation dazwischen). `.env`
   ist gitignored, wird nie committet.
4. `make up` — zieht `ghcr.io/pt9912/d-migrate:1.2.0` und
   `postgres:17.10-trixie`, startet Postgres, wartet auf „healthy“, dann
   den MCP-Server (registriert `local_pg`, migriert das
   `dmigrate_state`-Schema).
5. Projekt in Claude Code öffnen. `.mcp.json` ist eingecheckt, aber
   **standardmäßig nicht vertraut** — Claude Code zeigt `d-migrate` als
   „⏸ Pending approval“, bis einmal bestätigt wird (`claude mcp list` /
   `/mcp`-Prompt). Neue Tools erscheinen erst in einer danach frisch
   gestarteten Session.
6. `./state` (dateibasierte MCP-Artefakte) und das `pg-data`-Docker-Volume
   entstehen beim ersten Start, sind gitignored und lokal — ein frischer
   Clone startet mit leerem State.

## How it's wired

- **Auth**: `--auth-mode disabled`, strikt Loopback-only (`127.0.0.1`).
- **MCP-State-Dir**: `./state`, in den Container gemountet, Host-User-Owned
  (`.env` setzt `UID`/`GID`) — dateibasierte Upload-Segmente/Artefakte.
- **DB-Connection**: lokales Postgres (`postgres:17.10-trixie`,
  `127.0.0.1:${PG_PORT:-5433}`) als Connection `local_pg`
  (`.d-migrate.yaml`, Tenant `default`).
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
make up        # start (postgres, then d-migrate-mcp)
make down      # stop
make down-v    # stop and also drop the postgres volume
make logs      # tail logs
make restart   # restart d-migrate-mcp — pick up .d-migrate.yaml / policy-rules.yaml edits
```

## Docs

- [Anwenderhandbuch](https://github.com/pt9912/d-migrate/blob/main/docs/user/anwenderhandbuch.md)
- [Administrationshandbuch](https://github.com/pt9912/d-migrate/blob/main/docs/user/administrationshandbuch.md)
- [MCP server spec](https://github.com/pt9912/d-migrate/blob/main/spec/mcp-server.md)

## Upgrading

Bump the image tag in `docker-compose.yml` (pinned to `1.2.0`), then
`make up`.

For production/multi-host use, switch `--auth-mode` to `jwt-jwks` (see
spec §6.2) instead of binding non-loopback with auth disabled.
