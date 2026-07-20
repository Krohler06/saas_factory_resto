#!/usr/bin/env bash

set -Eeuo pipefail

CLIENT_DIR="${1:-/opt/clients/little_africa_nice}"

TENANT_FILE="${TENANT_FILE:-/root/saas_factory/tenants/private/little_africa_nice.yml}"

SEED_FILE="${SEED_FILE:-/root/saas_factory/generated/little_africa_nice/sql/010-booking-engine-v2-seed.sql}"

REPORT_FILE="${REPORT_FILE:-/root/saas_factory/generated/booking-engine-v2/data-test-report.txt}"

fatal() {
  printf '[ERREUR] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\n[INFO] %s\n' "$*"
}

ok() {
  printf '[OK] %s\n' "$*"
}

[[ -d "$CLIENT_DIR" ]] ||
  fatal "Répertoire client absent : $CLIENT_DIR"

[[ -f "$CLIENT_DIR/.env" ]] ||
  fatal "Fichier .env absent."

[[ -f "$TENANT_FILE" ]] ||
  fatal "Fichier tenant absent : $TENANT_FILE"

cd "$CLIENT_DIR"

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  fatal "Docker Compose absent."
fi

set -a
# shellcheck disable=SC1091
source "$CLIENT_DIR/.env"
set +a

POSTGRES_DB="${POSTGRES_DB:-${PG_DB:-}}"
POSTGRES_USER="${POSTGRES_USER:-${PG_USER:-}}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${PG_PASSWORD:-}}"

TEST_DB="${BOOKING_V2_TEST_DB:-${POSTGRES_DB}_booking_v2_test}"

mkdir -p "$(dirname "$SEED_FILE")"
mkdir -p "$(dirname "$REPORT_FILE")"

info "Génération du seed SQL"

python3 \
  /root/saas_factory/scripts/generate-booking-v2-seed.py \
  "$TENANT_FILE" \
  "$SEED_FILE"

info "Validation SQL dans une transaction annulée"

{
  printf 'BEGIN;\n'

  awk '
    $0 != "BEGIN;" && $0 != "COMMIT;" {
      print
    }
  ' "$SEED_FILE"

  printf 'ROLLBACK;\n'
} |
"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  postgres \
  psql \
  -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_USER" \
  -d "$TEST_DB"

info "Application réelle sur la base de test"

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  postgres \
  psql \
  -v ON_ERROR_STOP=1 \
  -U "$POSTGRES_USER" \
  -d "$TEST_DB" \
  < "$SEED_FILE"

info "Génération du rapport de données"

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="$POSTGRES_PASSWORD" \
  postgres \
  psql \
  -U "$POSTGRES_USER" \
  -d "$TEST_DB" \
  -P pager=off \
  -c "
SELECT
    r.id,
    r.name,
    r.slug,
    r.timezone,
    s.max_party_size,
    s.cleaning_buffer_minutes,
    s.allow_combined_tables,
    s.booking_policy
FROM restaurants r
JOIN restaurant_settings s
  ON s.restaurant_id = r.id
WHERE r.slug = (
    SELECT regexp_replace(
        line,
        '^.*restaurant_slug:[[:space:]]*',
        ''
    )
    FROM regexp_split_to_table(
        pg_read_file('/dev/null', 0, 0, true),
        E'\n'
    ) line
    LIMIT 0
);
" >/dev/null 2>&1 || true

RESTAURANT_SLUG="$(
  awk '
    /^[[:space:]]*restaurant_slug:/ {
      sub(/^[[:space:]]*restaurant_slug:[[:space:]]*/, "")
      gsub(/["'\'']/, "")
      print
      exit
    }
  ' "$TENANT_FILE"
)"

{
  echo "============================================================"
  echo "BOOKING ENGINE V2 - DONNEES DE TEST"
  echo "============================================================"
  echo
  echo "Base : $TEST_DB"
  echo "Restaurant : $RESTAURANT_SLUG"
  echo "Date : $(date --iso-8601=seconds)"

  echo
  echo "============================================================"
  echo "PARAMETRES"
  echo "============================================================"

  "${COMPOSE[@]}" exec -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    postgres \
    psql \
    -U "$POSTGRES_USER" \
    -d "$TEST_DB" \
    -P pager=off \
    -c "
SELECT
    r.id,
    r.name,
    r.slug,
    r.timezone,
    s.max_party_size,
    s.cleaning_buffer_minutes,
    s.allow_combined_tables,
    s.booking_policy
FROM restaurants r
JOIN restaurant_settings s
  ON s.restaurant_id = r.id
WHERE r.slug = '$RESTAURANT_SLUG';
"

  echo
  echo "============================================================"
  echo "SERVICES"
  echo "============================================================"

  "${COMPOSE[@]}" exec -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    postgres \
    psql \
    -U "$POSTGRES_USER" \
    -d "$TEST_DB" \
    -P pager=off \
    -c "
SELECT
    sd.id,
    sd.slug,
    sd.name,
    sd.default_duration_minutes,
    sd.slot_interval_minutes,
    sd.priority,
    sd.is_active
FROM restaurant_service_definitions sd
JOIN restaurants r
  ON r.id = sd.restaurant_id
WHERE r.slug = '$RESTAURANT_SLUG'
ORDER BY sd.priority, sd.slug;
"

  echo
  echo "============================================================"
  echo "HORAIRES"
  echo "============================================================"

  "${COMPOSE[@]}" exec -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    postgres \
    psql \
    -U "$POSTGRES_USER" \
    -d "$TEST_DB" \
    -P pager=off \
    -c "
SELECT
    sh.weekday,
    CASE sh.weekday
      WHEN 1 THEN 'lundi'
      WHEN 2 THEN 'mardi'
      WHEN 3 THEN 'mercredi'
      WHEN 4 THEN 'jeudi'
      WHEN 5 THEN 'vendredi'
      WHEN 6 THEN 'samedi'
      WHEN 7 THEN 'dimanche'
    END AS jour,
    sd.slug AS service,
    sh.opens_at,
    sh.first_booking_at,
    sh.last_booking_at,
    sh.closes_at,
    sh.closes_next_day,
    sh.is_open
FROM restaurant_service_hours sh
JOIN restaurant_service_definitions sd
  ON sd.id = sh.service_id
JOIN restaurants r
  ON r.id = sh.restaurant_id
WHERE r.slug = '$RESTAURANT_SLUG'
ORDER BY sh.weekday, sd.priority;
"

  echo
  echo "============================================================"
  echo "ZONES"
  echo "============================================================"

  "${COMPOSE[@]}" exec -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    postgres \
    psql \
    -U "$POSTGRES_USER" \
    -d "$TEST_DB" \
    -P pager=off \
    -c "
SELECT
    a.id,
    a.slug,
    a.name,
    a.capacity,
    a.priority,
    a.customer_selectable,
    a.accessible,
    ARRAY_AGG(aa.alias ORDER BY aa.alias)
      FILTER (WHERE aa.alias IS NOT NULL) AS aliases
FROM restaurant_areas a
JOIN restaurants r
  ON r.id = a.restaurant_id
LEFT JOIN restaurant_area_aliases aa
  ON aa.area_id = a.id
WHERE r.slug = '$RESTAURANT_SLUG'
GROUP BY
    a.id,
    a.slug,
    a.name,
    a.capacity,
    a.priority,
    a.customer_selectable,
    a.accessible
ORDER BY a.priority, a.slug;
"

  echo
  echo "============================================================"
  echo "FERMETURES MATERIALISEES"
  echo "============================================================"

  "${COMPOSE[@]}" exec -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    postgres \
    psql \
    -U "$POSTGRES_USER" \
    -d "$TEST_DB" \
    -P pager=off \
    -c "
SELECT
    c.reason,
    c.starts_at AT TIME ZONE r.timezone AS local_start,
    c.ends_at AT TIME ZONE r.timezone AS local_end,
    sd.slug AS service,
    c.all_day,
    c.closure_type,
    c.source_key
FROM restaurant_closures c
JOIN restaurants r
  ON r.id = c.restaurant_id
LEFT JOIN restaurant_service_definitions sd
  ON sd.id = c.service_id
WHERE r.slug = '$RESTAURANT_SLUG'
ORDER BY c.starts_at, sd.slug NULLS FIRST;
"
} > "$REPORT_FILE"

ok "Seed appliqué sur la base de test."
ok "Rapport : $REPORT_FILE"

cat "$REPORT_FILE"
