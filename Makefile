DOCKER_COMPOSE ?= docker compose
HARNESS_TOOL_IMAGE ?= dmigrate-harness-tools:local
HARNESS_PYTHON_IMAGE ?= dmigrate-harness-python:local

-include .env

.PHONY: up down down-v logs restart smoke harness-tools type-matrix

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

# Werkzeug-Images fuer die Test-Skripte: Default-Stage = sqlite3 +
# mod_spatialite (SQLite-/SpatiaLite-Legs), `--target py` = python3
# (Typcheck der Matrix). Smoke und Typ-Matrix bauen sie bei Bedarf selbst;
# dieses Target ist fuer den expliziten Build.
harness-tools:
	docker build -t $(HARNESS_TOOL_IMAGE) tools/harness-tools
	docker build --target py -t $(HARNESS_PYTHON_IMAGE) tools/harness-tools

smoke:
	HARNESS_TOOL_IMAGE=$(HARNESS_TOOL_IMAGE) bash scripts/roundtrip-smoke.sh $(UPDATE)

type-matrix:
	HARNESS_TOOL_IMAGE=$(HARNESS_TOOL_IMAGE) PYTHON_IMAGE=$(HARNESS_PYTHON_IMAGE) bash scripts/type-matrix.sh $(KEEP)
