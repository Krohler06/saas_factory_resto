#!/usr/bin/env bash
set -Eeuo pipefail

CLIENT_DIR="${1:?Usage: init-tenant-db.sh /opt/clients/<client_id>}"

cd "$CLIENT_DIR"
set -a
source .env
set +a

PG_CONTAINER="${CLIENT_ID}_postgres"

if ! docker ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
echo "ERREUR: conteneur Postgres non démarré: $PG_CONTAINER" >&2
exit 1
fi

if [ -f "$CLIENT_DIR/sql/migrations/001_schema_current.sql" ]; then
echo "Application schema current"
docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$PG_CONTAINER"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"
< "$CLIENT_DIR/sql/migrations/001_schema_current.sql"
else
echo "WARN: schema SQL absent: $CLIENT_DIR/sql/migrations/001_schema_current.sql"
fi

if [ -f "$CLIENT_DIR/sql/seeds/seed-restaurant.sql" ]; then
echo "Seed restaurant"
docker exec -i -e PGPASSWORD="$POSTGRES_PASSWORD" "$PG_CONTAINER"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"
< "$CLIENT_DIR/sql/seeds/seed-restaurant.sql"
else
echo "WARN: seed restaurant absent"
fi

echo "DB initialisée."
