# d-migrate MCP (HTTP)

**English** | [Deutsch](README.de.md)

## What is d-migrate MCP (HTTP)?

A local Docker Compose setup that runs the
[d-migrate](https://github.com/pt9912/d-migrate) MCP server (HTTP
transport) against real Postgres and SQL Server test databases and
registers it project-scoped in Claude Code (`.mcp.json`). For anyone who
wants to call
d-migrate's schema/data tools as MCP tools from a Claude Code session
without building/installing d-migrate by hand or wiring up connections and
state manually.

## What can I do today?

- `make up` starts Postgres and the MCP server; it's then reachable at
  `http://127.0.0.1:8787/mcp`.
- Once you approve the project-scoped `.mcp.json` server in Claude Code,
  22 tools are available (`schema_validate`, `schema_reverse_start`,
  `data_profile_start`, `job_status_get`, …).
- `schema_reverse_start` against either wired-up connection (`local_pg`,
  `local_mssql`) returns `SUCCEEDED` with an artifact — verified via live
  tool calls against both.
- A running job survives `docker compose restart d-migrate-mcp` —
  server-state lives in Postgres, not in-memory; verified (job created
  before a restart, `job_status_get` returns the same status afterwards).
- `policy-rules.yaml` lets read-only/planning `*_start` tools through;
  write tools stay blocked without an approval (`policy:no-rule` with no
  rule, `challenge` with one) — both checked against live tool calls.

## Why d-migrate MCP (HTTP)?

The MCP server on its own (no connection config, no policy file, no
server-state) starts in seconds, but can then only work against schema
files — any tool that touches a real database either has nothing to
resolve (no registered connection) or gets rejected by the fail-closed
policy. The alternative would be wiring that up by hand every time. This
repo bundles the minimum needed once, locally, without the full auth
infrastructure (`jwt-jwks`) that's only needed for non-loopback operation.

## Core idea

As little configuration as possible, but enough to make real DB tools
usable: every extra file (`.d-migrate.yaml`, `policy-rules.yaml`, the
Postgres service) exists only because some concrete tool would otherwise
fail to run — not speculatively.

## What makes it trustworthy?

- **Auth boundary:** `--auth-mode disabled` is strictly loopback-only on
  the server side (boot validation rejects a non-loopback bind, no silent
  fallback) — [Administrationshandbuch §9.1](https://github.com/pt9912/d-migrate/blob/main/docs/user/administrationshandbuch.md#9-sicherheit).
- **Policy:** without a matching rule in `policy-rules.yaml`, every
  `*_start` job is `Deny` by default (`policy:no-rule`), fail-closed —
  [Administrationshandbuch §6.7](https://github.com/pt9912/d-migrate/blob/main/docs/user/administrationshandbuch.md#67-policy-gesteuerte-datenoperationen).
- **Persistence:** server-state lives in the Postgres schema
  `dmigrate_state` (Flyway-migrated), not in-memory — verified by a job
  surviving a container restart, not just claimed.
- **Canonical sources:** [Anwenderhandbuch](https://github.com/pt9912/d-migrate/blob/main/docs/user/anwenderhandbuch.md),
  [Administrationshandbuch](https://github.com/pt9912/d-migrate/blob/main/docs/user/administrationshandbuch.md),
  [MCP server spec](https://github.com/pt9912/d-migrate/blob/main/spec/mcp-server.md)
  in the d-migrate repo — this README points to them, it doesn't
  duplicate them.

---

## Setup (after cloning)

1. **Docker + Docker Compose v2** required. `network_mode: host` (used so
   the container can bind loopback yet stay reachable from the host) is
   **Linux-only** — this setup does not work as-is on macOS/Windows Docker
   Desktop.
2. Ports must be free on the host: `8787` (MCP), `5433` (Postgres, see
   `PG_PORT`) and `1433` (SQL Server, see `MSSQL_PORT`) in `.env` — pick
   others if they collide with something else you have running.
3. `cp .env.example .env` and set real passwords — `POSTGRES_PASSWORD`
   and `MSSQL_SA_PASSWORD` each have to stay in sync with the password
   embedded in `D_MIGRATE_LOCAL_PG_URL` / `D_MIGRATE_LOCAL_MSSQL_URL`
   (same file, two places each; there's no variable substitution across
   them). `MSSQL_SA_PASSWORD` must meet SQL Server's complexity rule (8+
   chars, 3 of 4 categories) and avoid URL-reserved characters
   (`@ : / ? # %`) so it doesn't need percent-encoding in the URL. `.env`
   is gitignored, never committed.
4. `make up` — pulls `ghcr.io/pt9912/d-migrate:1.2.0`,
   `postgres:17.10-trixie` and `mcr.microsoft.com/mssql/server:2022-latest`,
   starts Postgres and SQL Server, waits for both to be healthy, runs a
   one-shot `mssql-init` step that creates the `dmigrate` database (SQL
   Server's default `master` database is deliberately not used as the
   target), then starts the MCP server (registers `local_pg` and
   `local_mssql`, migrates the `dmigrate_state` schema).
5. Open this project in Claude Code. `.mcp.json` is checked in but
   **untrusted by default** — Claude Code shows the `d-migrate` server as
   "⏸ Pending approval" until you approve it once (`claude mcp list` /
   the `/mcp` prompt). New tools only show up in a *fresh* Claude Code
   session started after approval.
6. `./state` (file-backed MCP artifacts) and the `pg-data` Docker volume
   are created on first run, gitignored, and local to your machine — a
   fresh clone starts with empty state.

## How it's wired

- **Auth**: `--auth-mode disabled` — strictly loopback-only (`127.0.0.1`).
- **MCP state dir**: `./state`, bind-mounted into the container and owned
  by the host user (`.env` sets `UID`/`GID`) — holds file-backed upload
  segments and artifact content.
- **DB connections**: a local Postgres (`postgres:17.10-trixie`,
  `127.0.0.1:${PG_PORT:-5433}`) as `local_pg`, and a local SQL Server
  (`mcr.microsoft.com/mssql/server:2022-latest`,
  `127.0.0.1:${MSSQL_PORT:-1433}`, database `dmigrate`) as `local_mssql`
  (`.d-migrate.yaml`, tenant `default`).
- **Server-state**: jobs, quotas, idempotency, schema/artifact stores are
  JDBC-backed in the same Postgres, schema `dmigrate_state`
  (`server.state` in `.d-migrate.yaml`, `migrations.auto: true`).
- **Policy**: `policy-rules.yaml` allows read-only/planning `*_start`
  tools for tenant `default`; write tools (`data_import_start`,
  `data_transfer_start`, `testdata_execute`,
  `procedure_transform_execute`) require an approval
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
