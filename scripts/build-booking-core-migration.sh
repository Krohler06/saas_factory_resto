#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

CLIENT_DIR="${1:-/opt/clients/little_africa_nice}"
FACTORY_DIR="${FACTORY_DIR:-/root/saas_factory}"

OUTPUT_FILE="$FACTORY_DIR/template/sql/migrations/001-booking-core.sql"
TEMP_FILE="${OUTPUT_FILE}.tmp"

info() {
  printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

ok() {
  printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

fatal() {
  printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2
  exit 1
}

[[ -d "$CLIENT_DIR" ]] ||
  fatal "Répertoire client absent : $CLIENT_DIR"

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

POSTGRES_DB="${POSTGRES_DB:-${PG_DB:-}}"
POSTGRES_USER="${POSTGRES_USER:-${PG_USER:-}}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${PG_PASSWORD:-}}"

[[ -n "$POSTGRES_DB" ]] ||
  fatal "POSTGRES_DB ou PG_DB absent."

[[ -n "$POSTGRES_USER" ]] ||
  fatal "POSTGRES_USER ou PG_USER absent."

[[ -n "$POSTGRES_PASSWORD" ]] ||
  fatal "POSTGRES_PASSWORD ou PG_PASSWORD absent."

SERVICES="$("${COMPOSE[@]}" config --services)"

POSTGRES_SERVICE="$(
  printf '%s\n' "$SERVICES" |
    grep -Ei '^(postgres|postgresql|db|database)$' |
    head -n1 || true
)"

if [[ -z "$POSTGRES_SERVICE" ]]; then
  POSTGRES_SERVICE="$(
    printf '%s\n' "$SERVICES" |
      grep -Ei 'postgres|postgresql|database|db' |
      head -n1 || true
  )"
fi

[[ -n "$POSTGRES_SERVICE" ]] ||
  fatal "Service PostgreSQL non détecté."

db_exec() {
  "${COMPOSE[@]}" exec -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    "$POSTGRES_SERVICE" \
    psql \
    -v ON_ERROR_STOP=1 \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    "$@"
}

BUSINESS_TABLES=(
  restaurants
  restaurant_settings
  restaurant_channels
  clients
  reservations
  restaurant_closures
  client_notifications
  reservation_events
  client_receivers
  conversation_sessions
  channel_conversation_logs
  outbound_messages
)

PG_DUMP_ARGS=()
SELECTED_TABLES=()

info "Recherche des tables métier présentes dans $POSTGRES_DB"

for table in "${BUSINESS_TABLES[@]}"; do
  exists="$(
    db_exec -Atc "
      SELECT EXISTS (
        SELECT 1
        FROM information_schema.tables
        WHERE table_schema = 'public'
          AND table_name = '$table'
      );
    "
  )"

  if [[ "$exists" == "t" ]]; then
    PG_DUMP_ARGS+=("--table=public.${table}")
    SELECTED_TABLES+=("$table")
    printf '[OK] %s\n' "$table"
  else
    warn "Table absente et ignorée : $table"
  fi
done

[[ "${#SELECTED_TABLES[@]}" -gt 0 ]] ||
  fatal "Aucune table métier trouvée."

mkdir -p "$(dirname "$OUTPUT_FILE")"

info "Export du schéma métier"

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  "$POSTGRES_SERVICE" \
  pg_dump \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  --schema-only \
  --no-owner \
  --no-privileges \
  "${PG_DUMP_ARGS[@]}" \
  > "$TEMP_FILE"

[[ -s "$TEMP_FILE" ]] ||
  fatal "Le fichier SQL généré est vide."

grep -qE '^CREATE TABLE public\.restaurants' "$TEMP_FILE" ||
  fatal "La table restaurants est absente de la migration."

grep -qE '^CREATE TABLE public\.restaurant_settings' "$TEMP_FILE" ||
  fatal "La table restaurant_settings est absente de la migration."

grep -qE '^CREATE TABLE public\.reservations' "$TEMP_FILE" ||
  fatal "La table reservations est absente de la migration."

mv "$TEMP_FILE" "$OUTPUT_FILE"
chmod 0644 "$OUTPUT_FILE"

ok "Migration créée : $OUTPUT_FILE"

printf '\nTables exportées :\n'

printf '  - %s\n' "${SELECTED_TABLES[@]}"

printf '\nContrôle rapide :\n'

grep -E '^CREATE TABLE public\.' "$OUTPUT_FILE" |
  sed 's/^CREATE TABLE public\./  - /; s/ (.*//'
