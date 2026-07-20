#!/usr/bin/env bash

set -Eeuo pipefail

CLIENT_INPUT="${1:-}"

FACTORY_DIR="${FACTORY_DIR:-/root/saas_factory}"
CLIENTS_DIR="${CLIENTS_DIR:-/opt/clients}"

log() {
  printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

success() {
  printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

fatal() {
  printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage :

  export-tenant.sh little_africa_nice

ou :

  export-tenant.sh /opt/clients/little_africa_nice
USAGE
}

[[ -n "$CLIENT_INPUT" ]] || {
  usage
  exit 1
}

if [[ "$CLIENT_INPUT" == /* ]]; then
  CLIENT_DIR="$CLIENT_INPUT"
else
  CLIENT_DIR="$CLIENTS_DIR/$CLIENT_INPUT"
fi

[[ -d "$CLIENT_DIR" ]] ||
  fatal "Tenant introuvable : $CLIENT_DIR"

[[ -f "$CLIENT_DIR/.env" ]] ||
  fatal "Fichier .env absent : $CLIENT_DIR/.env"

cd "$CLIENT_DIR"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  fatal "Docker Compose est introuvable."
fi

set -a
# shellcheck disable=SC1091
source "$CLIENT_DIR/.env"
set +a

CLIENT_ID="${CLIENT_ID:-$(basename "$CLIENT_DIR")}"

POSTGRES_DB="${POSTGRES_DB:-${PG_DB:-}}"
POSTGRES_USER="${POSTGRES_USER:-${PG_USER:-}}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${PG_PASSWORD:-}}"

[[ -n "$POSTGRES_DB" ]] || fatal "Base PostgreSQL non définie."
[[ -n "$POSTGRES_USER" ]] || fatal "Utilisateur PostgreSQL non défini."
[[ -n "$POSTGRES_PASSWORD" ]] || fatal "Mot de passe PostgreSQL non défini."

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
EXPORT_DIR="$FACTORY_DIR/exports/${CLIENT_ID}_${TIMESTAMP}"

mkdir -p \
  "$EXPORT_DIR/meta" \
  "$EXPORT_DIR/docker" \
  "$EXPORT_DIR/env" \
  "$EXPORT_DIR/sql/schema" \
  "$EXPORT_DIR/sql/data" \
  "$EXPORT_DIR/sql/reports" \
  "$EXPORT_DIR/n8n/workflows" \
  "$EXPORT_DIR/caddy" \
  "$EXPORT_DIR/tests" \
  "$EXPORT_DIR/logs"

SERVICES="$("${COMPOSE[@]}" config --services)"

POSTGRES_SERVICE="$(
  printf '%s\n' "$SERVICES" |
    grep -Ei '^(postgres|postgresql|db|database)$' |
    head -n1 || true
)"

if [[ -z "$POSTGRES_SERVICE" ]]; then
  POSTGRES_SERVICE="$(
    printf '%s\n' "$SERVICES" |
      grep -Ei 'postgres|database|db' |
      head -n1 || true
  )"
fi

N8N_SERVICE="$(
  printf '%s\n' "$SERVICES" |
    grep -Ei '^n8n$|n8n' |
    head -n1 || true
)"

[[ -n "$POSTGRES_SERVICE" ]] ||
  fatal "Service PostgreSQL non détecté."

psql_exec() {
  "${COMPOSE[@]}" exec -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    "$POSTGRES_SERVICE" \
    psql \
    -v ON_ERROR_STOP=1 \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    "$@"
}

log "Export du tenant $CLIENT_ID"

###############################################################################
# Docker
###############################################################################

for file in \
  docker-compose.yml \
  docker-compose.yaml \
  compose.yml \
  compose.yaml
do
  [[ -f "$file" ]] && cp -a "$file" "$EXPORT_DIR/docker/"
done

"${COMPOSE[@]}" config \
  > "$EXPORT_DIR/docker/docker-compose.resolved.yml"

"${COMPOSE[@]}" ps -a \
  > "$EXPORT_DIR/docker/containers.txt"

###############################################################################
# Environnement anonymisé
###############################################################################

cp -a .env "$EXPORT_DIR/env/.env.reference"

sed -E -i \
  -e 's#(PASSWORD=).*#\1__REDACTED__#g' \
  -e 's#(TOKEN=).*#\1__REDACTED__#g' \
  -e 's#(SECRET=).*#\1__REDACTED__#g' \
  -e 's#(API_KEY=).*#\1__REDACTED__#g' \
  -e 's#(N8N_ENCRYPTION_KEY=).*#\1__REDACTED__#g' \
  "$EXPORT_DIR/env/.env.reference" \
  "$EXPORT_DIR/docker/docker-compose.resolved.yml"

###############################################################################
# PostgreSQL : schéma et dump complet
###############################################################################

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  "$POSTGRES_SERVICE" \
  pg_dump \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  --schema-only \
  --no-owner \
  --no-privileges \
  > "$EXPORT_DIR/sql/schema/schema.sql"

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  "$POSTGRES_SERVICE" \
  pg_dump \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  --format=custom \
  --no-owner \
  --no-privileges \
  > "$EXPORT_DIR/sql/database.dump"

###############################################################################
# Rapports
###############################################################################

psql_exec -A -F $'\t' -P pager=off -c "
SELECT
    table_name,
    ordinal_position,
    column_name,
    data_type,
    udt_name,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_schema = 'public'
ORDER BY table_name, ordinal_position;
" > "$EXPORT_DIR/sql/reports/columns.tsv"

psql_exec -A -F $'\t' -P pager=off -c "
SELECT
    c.conrelid::regclass::text AS table_name,
    c.conname,
    c.contype,
    pg_get_constraintdef(c.oid) AS definition
FROM pg_constraint c
WHERE c.connamespace = 'public'::regnamespace
ORDER BY c.conrelid::regclass::text, c.conname;
" > "$EXPORT_DIR/sql/reports/constraints.tsv"

psql_exec -A -F $'\t' -P pager=off -c "
SELECT
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;
" > "$EXPORT_DIR/sql/reports/indexes.tsv"

###############################################################################
# Données de référence
###############################################################################

REFERENCE_TABLES=(
  restaurants
  restaurant_settings
  restaurant_closures
  restaurant_service_definitions
  restaurant_service_hours
  restaurant_areas
  restaurant_area_aliases
  restaurant_recurring_closures
  restaurant_tables
)

for table in "${REFERENCE_TABLES[@]}"; do
  exists="$(
    psql_exec -Atc "
      SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = '${table}'
      );
    "
  )"

  if [[ "$exists" == "t" ]]; then
    "${COMPOSE[@]}" exec -T \
      -e PGPASSWORD="$POSTGRES_PASSWORD" \
      "$POSTGRES_SERVICE" \
      pg_dump \
      -U "$POSTGRES_USER" \
      -d "$POSTGRES_DB" \
      --data-only \
      --column-inserts \
      --no-owner \
      --no-privileges \
      --table="public.${table}" \
      > "$EXPORT_DIR/sql/data/${table}.sql"
  fi
done

###############################################################################
# n8n
###############################################################################

if [[ -n "$N8N_SERVICE" ]]; then
  log "Export n8n"

  "${COMPOSE[@]}" exec -T "$N8N_SERVICE" \
    sh -lc '
      rm -rf /tmp/n8n-tenant-export
      mkdir -p /tmp/n8n-tenant-export

      n8n export:workflow \
        --backup \
        --output=/tmp/n8n-tenant-export
    ' > "$EXPORT_DIR/logs/n8n-export.log" 2>&1 || true

  N8N_CONTAINER="$("${COMPOSE[@]}" ps -q "$N8N_SERVICE")"

  if [[ -n "$N8N_CONTAINER" ]]; then
    docker cp \
      "${N8N_CONTAINER}:/tmp/n8n-tenant-export/." \
      "$EXPORT_DIR/n8n/workflows/" 2>/dev/null || true
  fi
fi

###############################################################################
# Fichiers de tests et migrations du tenant
###############################################################################

if [[ -d "$CLIENT_DIR/tests" ]]; then
  cp -a "$CLIENT_DIR/tests/." "$EXPORT_DIR/tests/"
fi

if [[ -d "$CLIENT_DIR/migrations" ]]; then
  mkdir -p "$EXPORT_DIR/sql/migrations"
  cp -a "$CLIENT_DIR/migrations/." "$EXPORT_DIR/sql/migrations/"
fi

###############################################################################
# Manifeste
###############################################################################

cat > "$EXPORT_DIR/meta/tenant-manifest.txt" <<MANIFEST
client_id=$CLIENT_ID
source_directory=$CLIENT_DIR
exported_at=$(date --iso-8601=seconds)
postgres_database=$POSTGRES_DB
postgres_service=$POSTGRES_SERVICE
n8n_service=${N8N_SERVICE:-not_detected}
MANIFEST

find "$EXPORT_DIR" \
  -type f \
  ! -name SHA256SUMS \
  -print0 |
sort -z |
xargs -0 sha256sum \
  > "$EXPORT_DIR/SHA256SUMS"

success "Export terminé"
printf '\n%s\n' "$EXPORT_DIR"
