# d-migrate MCP (HTTP)

Runs the [d-migrate](https://github.com/pt9912/d-migrate) MCP server via
Docker Compose, reachable at `http://127.0.0.1:8787/mcp`, and registered in
Claude Code as the `d-migrate` MCP server (project config, `.mcp.json`).

## Setup (after cloning)

1. **Docker + Docker Compose v2** required. `network_mode: host` (used so
   the container can bind loopback yet stay reachable from the host) is
   **Linux-only** — this setup does not work as-is on macOS/Windows Docker
   Desktop.
2. Ports must be free on the host: `8787` (MCP) and `5433` (Postgres, see
   `PG_PORT` in `.env` — pick another if it collides with something else
   you have running).
3. `cp .env.example .env` and set a real `POSTGRES_PASSWORD` — keep it in
   sync with the password embedded in `D_MIGRATE_LOCAL_PG_URL` (same file,
   two places; there's no variable substitution across them). `.env` is
   gitignored, never committed.
4. `docker compose up -d` — pulls `ghcr.io/pt9912/d-migrate:1.2.0` and
   `postgres:17.10-trixie`, starts Postgres, waits for it to be healthy,
   then starts the MCP server (registers `local_pg`, migrates the
   `dmigrate_state` schema).
5. Open this project in Claude Code. `.mcp.json` is checked in but
   **untrusted by default** — Claude Code shows the `d-migrate` server as
   "⏸ Pending approval" until you approve it once (`claude mcp list` /
   the `/mcp` prompt). New tools only show up in a *fresh* Claude Code
   session started after approval.
6. `./state` (file-backed MCP artifacts) and the `pg-data` Docker volume
   are created on first run, gitignored, and local to your machine — a
   fresh clone starts with empty state.

## How it's wired

- **Auth**: `--auth-mode disabled` — strictly loopback-only (`127.0.0.1`),
  per [Administrationshandbuch §9.1](https://github.com/pt9912/d-migrate/blob/main/docs/user/administrationshandbuch.md#9-sicherheit).
  Not exposed beyond this host.
- **MCP state dir**: `./state`, bind-mounted into the container and owned
  by the host user (`.env` sets `UID`/`GID`) — holds file-backed upload
  segments and artifact content.
- **DB connection**: a local Postgres (`postgres:17.10-trixie`,
  `127.0.0.1:${PG_PORT:-5433}`) is wired in as connection `local_pg`
  (`.d-migrate.yaml`, tenant `default`), so DB-touching tools
  (`schema_reverse_start`, `data_profile_start`, …) actually have
  something to talk to.
- **Server-state**: jobs, quotas, idempotency, schema/artifact stores are
  JDBC-backed in the same Postgres, schema `dmigrate_state`
  (`server.state` in `.d-migrate.yaml`, Flyway-migrated on boot,
  `migrations.auto: true`) — survives container restarts instead of
  living in-memory.
- **Policy**: `policy-rules.yaml` allows read-only/planning `*_start`
  tools for tenant `default`; write tools (`data_import_start`,
  `data_transfer_start`, `testdata_execute`,
  `procedure_transform_execute`) require an approval
  (`mcp approval-grant issue`) — see
  [Administrationshandbuch §6.7](https://github.com/pt9912/d-migrate/blob/main/docs/user/administrationshandbuch.md#67-policy-gesteuerte-datenoperationen).
  Without `--policy-file` every `*_start` job is denied by default
  (`policy:no-rule`).

## Usage

```bash
docker compose up -d      # start (postgres, then d-migrate-mcp)
docker compose logs -f    # tail logs
docker compose down       # stop (add -v to also drop the postgres volume)
docker compose restart d-migrate-mcp  # pick up .d-migrate.yaml / policy-rules.yaml edits
```

## Docs

- [Anwenderhandbuch](https://github.com/pt9912/d-migrate/blob/main/docs/user/anwenderhandbuch.md)
- [Administrationshandbuch](https://github.com/pt9912/d-migrate/blob/main/docs/user/administrationshandbuch.md)
- [MCP server spec](https://github.com/pt9912/d-migrate/blob/main/spec/mcp-server.md)

## Upgrading

Bump the image tag in `docker-compose.yml` (pinned to `1.2.0`), then
`docker compose up -d`.

For production/multi-host use, switch `--auth-mode` to `jwt-jwks` (see
spec §6.2) instead of binding non-loopback with auth disabled.
