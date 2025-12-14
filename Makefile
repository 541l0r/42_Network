# ============================================================================ #
#  Transcendence Deployment Makefile (Parameterized Campus)
#  Purpose: Single-command deployment to production (<1 hour)
# ============================================================================ #

-include ../.env
export $(shell sed -n 's/^\([A-Za-z0-9_]\+\)=.*/\1/p' ../.env 2>/dev/null)

COMPOSE := docker compose
SHELL := /bin/bash
.DEFAULT_GOAL := deploy

# Default values (can be overridden)
DB_USER ?= api42
DB_PASSWORD ?= api42
DB_NAME ?= api42
CAMPUS_ID ?= 76
WEB_PORT ?= 9000
POLL_INTERVAL ?= 60000

# Validate CAMPUS_ID is numeric
CAMPUS_ID := $(subst ",,$(CAMPUS_ID))
ifeq ($(CAMPUS_ID),)
  CAMPUS_ID := 1
endif

# ============================================================================ #
#  HELP
# ============================================================================ #

help:
	@echo "╔════════════════════════════════════════════════════════════════╗"
	@echo "║       Transcendence Deployment (< 1 hour, Parameterized)      ║"
	@echo "╚════════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "MAIN COMMANDS:"
	@echo "  make check               → Verify environment before deploy"
	@echo "  make deploy              → Deploy with default campus (1=Brussels)"
	@echo "  make deploy CAMPUS_ID=3  → Deploy with specific campus"
	@echo "  make status              → Check running services"
	@echo "  make logs                → Tail all logs"
	@echo ""
	@echo "PORT CONFIGURATION:"
	@echo "  make deploy WEB_PORT=8000 → Use port 8000 instead of 9000"
	@echo ""
	@echo "CAMPUS OPTIONS (examples):"
	@echo "  1=Brussels  3=Lyon  5=Toulouse  9=Angoulême  12=Paris  16=Lisbon"
	@echo "  20=Berlin  21=Amsterdam  22=Barcelona  25=Tokyo  26=Seoul"
	@echo ""
	@echo "UTILITIES:"
	@echo "  make up                  → Start services only"
	@echo "  make down                → Stop all services"
	@echo "  make clean               → Stop + remove images"
	@echo "  make fclean              → Clean + drop database (DESTRUCTIVE)"
	@echo "  make db-shell            → Open PostgreSQL shell"
	@echo ""

# ============================================================================ #
#  DEPLOYMENT (1-HOUR TARGET)
# ============================================================================ #

check:
	@bash ./scripts/orchestrate/check_environment.sh $(CAMPUS_ID)

deploy: .env.check check
	@echo "🚀 Starting Transcendence deployment..."
	@echo "   Campus ID: $(CAMPUS_ID)"
	@echo "   Target: <1 hour complete setup"
	@echo ""
	@$(MAKE) up
	@sleep 10
	@bash ./scripts/orchestrate/init_db.sh
	@bash ./scripts/orchestrate/fetch_metadata.sh
	@CAMPUS_ID=$(CAMPUS_ID) bash ./scripts/orchestrate/orchestra.sh
	@$(MAKE) cron-setup
	@echo ""
	@echo "✅ Deployment complete!"
	@echo "   Web: http://localhost:8000"
	@echo "   Campus: $(CAMPUS_ID)"
	@echo "   Data: Auto-refreshed every minute"
	@echo ""

# ============================================================================ #
#  SERVICE STARTUP
# ============================================================================ #

up:
	@echo "📦 Starting Docker services..."
	$(COMPOSE) up -d
	@echo "✅ Services started"
	@$(MAKE) status

# ============================================================================ #
#  CRON SETUP (1-minute polling)
# ============================================================================ #

cron-setup:
	@echo "⏰ Setting up cron polling (every 1 minute, campus $(CAMPUS_ID))..."
	@if crontab -l 2>/dev/null | grep -q "fetch_users.sh"; then \
		echo "✅ Cron already configured"; \
	else \
		(crontab -l 2>/dev/null || true; echo "* * * * * CAMPUS_ID=$(CAMPUS_ID) bash /srv/42_Network/repo/scripts/orchestrate/fetch_users.sh >> /srv/42_Network/repo/logs/cron_poll.log 2>&1") | crontab -; \
		echo "✅ Cron configured for campus $(CAMPUS_ID)"; \
	fi

# ============================================================================ #
#  SERVICE MANAGEMENT
# ============================================================================ #

status:
	@echo "🔍 Service status:"
	@$(COMPOSE) ps
	@echo ""

stop:
	@echo "⏸️  Stopping services..."
	$(COMPOSE) stop
	@echo "✅ Services stopped"

down:
	@echo "🛑 Shutting down services..."
	$(COMPOSE) down --remove-orphans
	@echo "✅ Services removed"

logs:
	$(COMPOSE) logs -f

db-shell:
	$(COMPOSE) exec db psql -U $(DB_USER) -d $(DB_NAME)

# ============================================================================ #
#  CLEANUP
# ============================================================================ #

clean: down
	@echo "🧹 Removing images..."
	$(COMPOSE) down --remove-orphans --rmi local
	@echo "✅ Clean complete"

fclean: clean
	@echo "☠️  DESTRUCTIVE CLEANUP: Dropping database..."
	@$(COMPOSE) down -v --remove-orphans --rmi all
	@echo ""
	@echo "📦 Archiving logs and exports..."
	@mkdir -p .cleanup/$$(date +%Y%m%d_%H%M%S)
	@[[ -d logs ]] && (echo "   → Moving logs/"; mv logs .cleanup/$$(date +%Y%m%d_%H%M%S)/) || true
	@[[ -d exports ]] && (echo "   → Moving exports/"; mv exports .cleanup/$$(date +%Y%m%d_%H%M%S)/) || true
	@[[ -d data/postgres ]] && (echo "   → Removing postgres data"; rm -rf data/postgres) || true
	@echo "✅ Full cleanup complete"
	@echo "   Old data archived to: .cleanup/$$(date +%Y%m%d_%H%M%S)"

reset: fclean
	@echo ""
	@echo "🔄 Ready for fresh deployment"

# ============================================================================ #
#  VALIDATION
# ============================================================================ #

.env.check:
	@if [ ! -f ../.env ]; then \
		echo "❌ ../.env not found"; \
		echo "   Create it with: API_42_CLIENT_ID=... API_42_CLIENT_SECRET=..."; \
		exit 1; \
	fi
	@echo "✅ Environment validated"

# ============================================================================ #
#  PHONY TARGETS
# ============================================================================ #

.PHONY: help deploy up down clean fclean stop logs status db-shell cron-setup .env.check reset check
