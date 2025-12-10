# **************************************************************************** #
#                                                                              #
#                                                         :::      ::::::::    #
#    init.sh                                            :+:      :+:    :+:    #
#                                                     +:+ +:+         +:+      #
#    By: matsauva <matsauva@student.s19.be>         +#+  +:+       +#+         #
#                                                 +#+#+#+#+#+   +#+            #
#    Created: 2025/12/09 13:40:28 by matsauva          #+#    #+#              #
#    Updated: 2025/12/09 14:23:23 by matsauva         ###   ########.fr        #
#                                                                              #
# **************************************************************************** #

#!/usr/bin/env bash
set -euo pipefail

COMPOSE=${COMPOSE:-docker compose}
DB_USER=${DB_USER//\"/}
DB_USER=${DB_USER:-api42}
DB_NAME=${DB_NAME//\"/}
DB_NAME=${DB_NAME:-api42}
DB_HOST=${DB_HOST//\"/}
DB_HOST=${DB_HOST:-db}
DB_PASSWORD=${DB_PASSWORD//\"/}
DB_PASSWORD=${DB_PASSWORD:-${POSTGRES_PASSWORD:-}}

if [ -z "$DB_PASSWORD" ]; then
  echo "DB_PASSWORD is not set; define it in .env or environment." >&2
  exit 1
fi

echo "Waiting for database to be ready..."

# Wait for DB to accept connections, then load schema via the psql helper container.
ATTEMPTS=10
for i in $(seq 1 $ATTEMPTS); do
  if $COMPOSE exec -T psql sh -c "PGPASSWORD='$DB_PASSWORD' psql -h '$DB_HOST' -U '$DB_USER' -d '$DB_NAME' -c 'select 1'" >/dev/null 2>&1; then
    break
  fi
  if [ "$i" -eq "$ATTEMPTS" ]; then
    echo "Database not ready after ${ATTEMPTS}s; recent db logs:"
    $COMPOSE logs --tail 50 db || true
    exit 1
  fi
  sleep 1
done

$COMPOSE exec -T psql sh -c "PGPASSWORD='$DB_PASSWORD' psql -h '$DB_HOST' -U '$DB_USER' -d '$DB_NAME' -v ON_ERROR_STOP=1 -f /workspace/data/schema.sql"
