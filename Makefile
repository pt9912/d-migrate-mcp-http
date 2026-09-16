DOCKER_COMPOSE ?= docker compose
SQLITE_TOOL_IMAGE ?= dmigrate-sqlite-tool:local

-include .env

.PHONY: up down down-v logs restart smoke sqlite-tool type-matrix

up:
	$(DOCKER_COMPOSE) up -d

down:
	$(DOCKER_COMPOSE) down

down-v:
	$(DOCKER_COMPOSE) down -v

logs:
	$(DOCKER_COMPOSE) logs -f

restart:
	$(DOCKER_COMPOSE) restart d-migrate-mcp

# Werkzeug-Image fuer den SQLite-/SpatiaLite-Leg (sqlite3 + mod_spatialite);
# der Smoke baut es bei Bedarf selbst, dieses Target ist fuer den expliziten Build.
sqlite-tool:
	docker build -t $(SQLITE_TOOL_IMAGE) tools/sqlite-spatial

smoke:
	bash scripts/roundtrip-smoke.sh $(UPDATE)

type-matrix:
	bash scripts/type-matrix.sh $(KEEP)
