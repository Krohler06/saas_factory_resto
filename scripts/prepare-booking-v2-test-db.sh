#!/usr/bin/env bash

set -Eeuo pipefail

CLIENT_DIR="${1:-/opt/clients/little_africa_nice}"
FACTORY_DIR="${FACTORY_DIR:-/root/saas_factory}"

MIGRATION_FILE="$FACTORY_DIR/template/sql/migrations/002-booking-engine-v2.sql"
BACKUP_DIR="$FACTORY_DIR/backups"
REPORT_DIR="$FACTORY_DIR/generated/booking-engine-v2"

info() {
  printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

ok() {
  printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

fatal() {
  printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2
  exit 1
}

[[ -d "$CLIENT_DIR" ]] ||
  fatal "Répertoire tenant absent : $CLIENT_DIR"

[[ -f "$CLIENT_DIR/.env" ]] ||
  fatal "Fichier .env absent : $CLIENT_DIR/.env"

[[ -f "$MIGRATION_FILE" ]] ||
  fatal "Migration absente : $MIGRATION_FILE"

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

TEST_DB="${BOOKING_V2_TEST_DB:-${POSTGRES_DB}_booking_v2_test}"

[[ "$TEST_DB" != "$POSTGRES_DB" ]] ||
  fatal "La base de test ne doit pas porter le nom de la production."

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
  fatal "Impossible de détecter le service PostgreSQL."

mkdir -p "$BACKUP_DIR" "$REPORT_DIR"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="$BACKUP_DIR/${POSTGRES_DB}_${TIMESTAMP}.dump"
REPORT_FILE="$REPORT_DIR/schema-test-report.txt"
TEST_SCHEMA_FILE="$REPORT_DIR/schema-booking-v2-test.sql"

db_exec() {
  local database="$1"
  shift

  "${COMPOSE[@]}" exec -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    "$POSTGRES_SERVICE" \
    psql \
    -v ON_ERROR_STOP=1 \
    -U "$POSTGRES_USER" \
    -d "$database" \
    "$@"
}

info "Vérification de la base source"

db_exec "$POSTGRES_DB" \
  -Atc 'SELECT current_database(), current_user;'

info "Sauvegarde de la production"

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  "$POSTGRES_SERVICE" \
  pg_dump \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  --format=custom \
  --no-owner \
  --no-privileges \
  > "$BACKUP_FILE"

[[ -s "$BACKUP_FILE" ]] ||
  fatal "Le dump PostgreSQL est vide."

ok "Sauvegarde créée : $BACKUP_FILE"

info "Suppression éventuelle de l'ancienne base de test"

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  "$POSTGRES_SERVICE" \
  dropdb \
  --if-exists \
  --force \
  -U "$POSTGRES_USER" \
  "$TEST_DB"

info "Création de la base de test"

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  "$POSTGRES_SERVICE" \
  createdb \
  -U "$POSTGRES_USER" \
  "$TEST_DB"

info "Restauration de la base actuelle dans la base de test"

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  "$POSTGRES_SERVICE" \
  pg_restore \
  -U "$POSTGRES_USER" \
  -d "$TEST_DB" \
  --no-owner \
  --no-privileges \
  < "$BACKUP_FILE"

info "Application de la migration Booking Engine V2"

db_exec "$TEST_DB" < "$MIGRATION_FILE"

info "Génération du rapport"

{
  echo "============================================================"
  echo "BOOKING ENGINE V2 - RAPPORT DE TEST"
  echo "============================================================"
  echo
  echo "Base source : $POSTGRES_DB"
  echo "Base de test : $TEST_DB"
  echo "Migration : $MIGRATION_FILE"
  echo "Dump : $BACKUP_FILE"
  echo "Date : $(date --iso-8601=seconds)"

  echo
  echo "============================================================"
  echo "TABLES V2"
  echo "============================================================"

  db_exec "$TEST_DB" -P pager=off -c "
    SELECT
        table_name
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name IN (
          'restaurant_service_definitions',
          'restaurant_service_hours',
          'restaurant_areas',
          'restaurant_area_aliases',
          'restaurant_tables',
          'reservation_tables'
      )
    ORDER BY table_name;
  "

  echo
  echo "============================================================"
  echo "COLONNES AJOUTEES A RESERVATIONS"
  echo "============================================================"

  db_exec "$TEST_DB" -P pager=off -c "
    SELECT
        column_name,
        data_type,
        is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'reservations'
      AND column_name IN (
          'service_id',
          'requested_area_id',
          'area_id',
          'table_id'
      )
    ORDER BY ordinal_position;
  "

  echo
  echo "============================================================"
  echo "COLONNES AJOUTEES AUX FERMETURES"
  echo "============================================================"

  db_exec "$TEST_DB" -P pager=off -c "
    SELECT
        column_name,
        data_type,
        is_nullable
    FROM information_schema.columns
    WHERE table_schema = 'public'
      AND table_name = 'restaurant_closures'
      AND column_name IN (
          'service_id',
          'area_id',
          'all_day',
          'source_key',
          'metadata'
      )
    ORDER BY ordinal_position;
  "

  echo
  echo "============================================================"
  echo "CONTRAINTES V2"
  echo "============================================================"

  db_exec "$TEST_DB" -P pager=off -c "
    SELECT
        conrelid::regclass AS table_name,
        conname,
        pg_get_constraintdef(oid) AS definition
    FROM pg_constraint
    WHERE connamespace = 'public'::regnamespace
      AND (
          conrelid::regclass::text LIKE 'restaurant_service_%'
          OR conrelid::regclass::text LIKE 'restaurant_area%'
          OR conrelid::regclass::text = 'restaurant_tables'
          OR conrelid::regclass::text = 'reservation_tables'
          OR conname LIKE 'fk_reservations_%'
          OR conname LIKE 'fk_restaurant_closures_%'
      )
    ORDER BY conrelid::regclass::text, conname;
  "

  echo
  echo "============================================================"
  echo "INDEX V2"
  echo "============================================================"

  db_exec "$TEST_DB" -P pager=off -c "
    SELECT
        tablename,
        indexname
    FROM pg_indexes
    WHERE schemaname = 'public'
      AND (
          tablename LIKE 'restaurant_service_%'
          OR tablename LIKE 'restaurant_area%'
          OR tablename = 'restaurant_tables'
          OR tablename = 'reservation_tables'
          OR indexname LIKE 'idx_reservations_%'
          OR indexname LIKE 'idx_restaurant_closures_%'
      )
    ORDER BY tablename, indexname;
  "

  echo
  echo "============================================================"
  echo "DONNEES DE PRODUCTION COPIEES"
  echo "============================================================"

  db_exec "$TEST_DB" -P pager=off -c "
    SELECT
        (SELECT COUNT(*) FROM restaurants) AS restaurants,
        (SELECT COUNT(*) FROM restaurant_settings) AS settings,
        (SELECT COUNT(*) FROM reservations) AS reservations,
        (SELECT COUNT(*) FROM restaurant_closures) AS closures;
  "
} > "$REPORT_FILE"

info "Export du schéma de test"

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  "$POSTGRES_SERVICE" \
  pg_dump \
  -U "$POSTGRES_USER" \
  -d "$TEST_DB" \
  --schema-only \
  --no-owner \
  --no-privileges \
  > "$TEST_SCHEMA_FILE"

ok "Base de test prête"
ok "Base : $TEST_DB"
ok "Rapport : $REPORT_FILE"
ok "Schéma : $TEST_SCHEMA_FILE"

printf '\n'
cat "$REPORT_FILE"
