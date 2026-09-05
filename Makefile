DOCKER_COMPOSE ?= docker compose

-include .env

.PHONY: up down down-v logs restart

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
