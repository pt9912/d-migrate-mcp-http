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

# Werkzeug-Image fuer die Test-Skripte (sqlite3 + mod_spatialite + python3);
# Smoke und Typ-Matrix bauen es bei Bedarf selbst, dieses Target ist fuer den
# expliziten Build.
harness-tools:
	docker build -t $(HARNESS_TOOL_IMAGE) tools/harness-tools
	docker build --target py -t $(HARNESS_PYTHON_IMAGE) tools/harness-tools

smoke:
	bash scripts/roundtrip-smoke.sh $(UPDATE)

type-matrix:
	bash scripts/type-matrix.sh $(KEEP)
