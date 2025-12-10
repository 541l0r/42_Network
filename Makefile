# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    Makefile                                           :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: matsauva <matsauva@student.s19.be>         +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2025/12/09 13:39:48 by matsauva          #+#    #+#              #
#    Updated: 2025/12/09 13:41:37 by matsauva         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

-include ../.env
export $(shell sed -n 's/^\([A-Za-z0-9_]\+\)=.*/\1/p' ../.env 2>/dev/null)

COMPOSE := docker compose
DB_USER := $(subst ",,$(DB_USER))
DB_USER ?= api42
DB_PASSWORD := $(subst ",,$(DB_PASSWORD))
DB_PASSWORD ?=
DB_NAME := $(subst ",,$(DB_NAME))
DB_NAME ?= api42
DB_HOST := $(subst ",,$(DB_HOST))
DB_HOST ?= db

.DEFAULT_GOAL := all

help:
	@echo "Targets (server setup):"
	@echo "  all       Alias for up"
	@echo "  up        Start database (db) and psql helper"
	@echo "  stop      Gracefully stop running containers (keep resources)"
	@echo "  down      Stop services, then remove them and the network"
	@echo "  logs      Tail logs from all services"
	@echo "  db-shell  Open a psql shell inside the db container"
	@echo "  re        clean + up"
	@echo "  reset     fclean"
	@echo "  launch    Bring up deps and run init script"
	@echo "  docker-ps Show running containers for this project"
	@echo "  clean     Stop/remove containers and network, prune local images"
	@echo "  fclean    clean + drop volumes and data dir (DROPS DATA!)"

# start the app

all: up

up:
	$(COMPOSE) up -d db psql
	bash ./init.sh

# just stop the containers 
stop:
	$(COMPOSE) stop

# will stop and remove the containers
down:
	$(COMPOSE) down --remove-orphans

# down + remove rmi
clean:
	$(COMPOSE) down --remove-orphans --rmi local

# down + remove rmi & data
fclean:
	$(COMPOSE) down -v --remove-orphans --rmi local
	@if [ -d ./data/postgres ]; then \
		docker run --rm -v $(PWD)/data/postgres:/var/lib/postgresql/data postgres:16 sh -c "rm -rf /var/lib/postgresql/data/*" || true; \
		echo "data/postgres volume contents removed"; \
	fi

re: clean up

reset: fclean

logs:
	$(COMPOSE) logs -f

db-shell:
	PGPASSWORD=$(DB_PASSWORD) $(COMPOSE) exec -T db psql -h $(DB_HOST) -U $(DB_USER) -d $(DB_NAME)

docker-ps:
	docker ps --filter "label=com.docker.compose.project=repo"

.PHONY: help all up down logs db-shell re fclean clean docker-ps stop reset
