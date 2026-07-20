#!/usr/bin/env bash

set -Eeuo pipefail

###############################################################################
# Configuration
###############################################################################

CLIENT_DIR="${1:-/opt/clients/little_africa_nice}"
FACTORY_DIR="${FACTORY_DIR:-/root/saas_factory}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
CLIENT_ID=""

EXPORT_DIR=""

###############################################################################
# Fonctions
###############################################################################

log() {
  printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

success() {
  printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2
}

fatal() {
  printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fatal "Commande absente : $1"
}

sanitize_file() {
  local file="$1"

  [[ -f "$file" ]] || return 0

  sed -E -i \
    -e 's#(POSTGRES_PASSWORD=).*#\1__REDACTED__#g' \
    -e 's#(N8N_ENCRYPTION_KEY=).*#\1__REDACTED__#g' \
    -e 's#(RETELL_API_KEY=).*#\1__REDACTED__#g' \
    -e 's#(RETELL_SECRET=).*#\1__REDACTED__#g' \
    -e 's#(OPENAI_API_KEY=).*#\1__REDACTED__#g' \
    -e 's#(API_KEY=).*#\1__REDACTED__#g' \
    -e 's#(TOKEN=).*#\1__REDACTED__#g' \
    -e 's#(PASSWORD=).*#\1__REDACTED__#g' \
    "$file"
}

detect_compose_command() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    fatal "Docker Compose est introuvable."
  fi
}

detect_postgres_service() {
  local services

  services="$("${COMPOSE[@]}" config --services 2>/dev/null || true)"

  POSTGRES_SERVICE="$(
    printf '%s\n' "$services" |
      grep -Ei '^(postgres|postgresql|db|database)$' |
      head -n1 || true
  )"

  if [[ -z "$POSTGRES_SERVICE" ]]; then
    POSTGRES_SERVICE="$(
      printf '%s\n' "$services" |
        grep -Ei 'postgres|database|db' |
        head -n1 || true
    )"
  fi

  [[ -n "$POSTGRES_SERVICE" ]] ||
    fatal "Impossible de détecter le service PostgreSQL dans Docker Compose."
}

detect_n8n_service() {
  local services

  services="$("${COMPOSE[@]}" config --services 2>/dev/null || true)"

  N8N_SERVICE="$(
    printf '%s\n' "$services" |
      grep -Ei '^n8n$|n8n' |
      head -n1 || true
  )"
}

psql_exec() {
  "${COMPOSE[@]}" exec -T \
    -e PGPASSWORD="${POSTGRES_PASSWORD}" \
    "$POSTGRES_SERVICE" \
    psql \
    -v ON_ERROR_STOP=1 \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    "$@"
}

###############################################################################
# Précontrôles
###############################################################################

require_command docker
require_command sed
require_command grep
require_command find
require_command sha256sum

[[ -d "$CLIENT_DIR" ]] ||
  fatal "Répertoire client introuvable : $CLIENT_DIR"

[[ -f "$CLIENT_DIR/.env" ]] ||
  fatal "Fichier .env introuvable : $CLIENT_DIR/.env"

cd "$CLIENT_DIR"

detect_compose_command

if [[ ! -f docker-compose.yml && ! -f compose.yml && ! -f compose.yaml ]]; then
  fatal "Aucun fichier Docker Compose trouvé dans $CLIENT_DIR"
fi

###############################################################################
# Chargement environnement
###############################################################################

set -a
# shellcheck disable=SC1091
source "$CLIENT_DIR/.env"
set +a

CLIENT_ID="${CLIENT_ID:-$(basename "$CLIENT_DIR")}"

POSTGRES_DB="${POSTGRES_DB:-${PG_DB:-}}"
POSTGRES_USER="${POSTGRES_USER:-${PG_USER:-}}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-${PG_PASSWORD:-}}"

[[ -n "$POSTGRES_DB" ]] ||
  fatal "POSTGRES_DB ou PG_DB absent du .env"

[[ -n "$POSTGRES_USER" ]] ||
  fatal "POSTGRES_USER ou PG_USER absent du .env"

[[ -n "$POSTGRES_PASSWORD" ]] ||
  fatal "POSTGRES_PASSWORD ou PG_PASSWORD absent du .env"

EXPORT_DIR="$FACTORY_DIR/exports/${CLIENT_ID}_booking_v2_context_${TIMESTAMP}"

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

log "Client       : $CLIENT_ID"
log "Répertoire   : $CLIENT_DIR"
log "Export       : $EXPORT_DIR"

###############################################################################
# Détection services
###############################################################################

detect_postgres_service
detect_n8n_service

log "Service PostgreSQL détecté : $POSTGRES_SERVICE"

if [[ -n "$N8N_SERVICE" ]]; then
  log "Service n8n détecté       : $N8N_SERVICE"
else
  warn "Service n8n non détecté automatiquement."
fi

###############################################################################
# Copie fichiers infrastructure
###############################################################################

log "Copie des fichiers Docker et environnement"

for file in \
  docker-compose.yml \
  docker-compose.yaml \
  compose.yml \
  compose.yaml
do
  if [[ -f "$file" ]]; then
    cp -a "$file" "$EXPORT_DIR/docker/"
  fi
done

cp -a "$CLIENT_DIR/.env" "$EXPORT_DIR/env/.env.reference"
sanitize_file "$EXPORT_DIR/env/.env.reference"

"${COMPOSE[@]}" config \
  > "$EXPORT_DIR/docker/docker-compose.resolved.yml"

sanitize_file "$EXPORT_DIR/docker/docker-compose.resolved.yml"

"${COMPOSE[@]}" config --services \
  > "$EXPORT_DIR/docker/services.txt"

"${COMPOSE[@]}" ps -a \
  > "$EXPORT_DIR/docker/containers.txt"

###############################################################################
# Vérification PostgreSQL
###############################################################################

log "Vérification PostgreSQL"

psql_exec -Atc 'SELECT current_database(), current_user, version();' \
  > "$EXPORT_DIR/sql/reports/postgres-version.txt"

success "Connexion PostgreSQL valide"

###############################################################################
# Export schéma PostgreSQL
###############################################################################

log "Export du schéma PostgreSQL"

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="${POSTGRES_PASSWORD}" \
  "$POSTGRES_SERVICE" \
  pg_dump \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  --schema-only \
  --no-owner \
  --no-privileges \
  > "$EXPORT_DIR/sql/schema/schema.sql"

"${COMPOSE[@]}" exec -T \
  -e PGPASSWORD="${POSTGRES_PASSWORD}" \
  "$POSTGRES_SERVICE" \
  pg_dump \
  -U "$POSTGRES_USER" \
  -d "$POSTGRES_DB" \
  --schema-only \
  --no-owner \
  --no-privileges \
  --table=public.restaurants \
  --table=public.restaurant_settings \
  --table=public.restaurant_closures \
  --table=public.reservations \
  > "$EXPORT_DIR/sql/schema/booking-current.sql" 2>/dev/null || true

###############################################################################
# Rapports SQL
###############################################################################

log "Création des rapports SQL"

psql_exec -A -F $'\t' -P pager=off -c "
SELECT
    table_schema,
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

psql_exec -A -F $'\t' -P pager=off -c "
SELECT
    table_name
FROM information_schema.tables
WHERE table_schema = 'public'
  AND table_type = 'BASE TABLE'
ORDER BY table_name;
" > "$EXPORT_DIR/sql/reports/tables.txt"

psql_exec -A -F $'\t' -P pager=off -c "
SELECT
    table_name,
    column_name,
    data_type,
    udt_name
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN (
      'restaurants',
      'restaurant_settings',
      'restaurant_closures',
      'reservations'
  )
ORDER BY table_name, ordinal_position;
" > "$EXPORT_DIR/sql/reports/booking-columns.tsv"

psql_exec -A -F $'\t' -P pager=off -c "
SELECT
    tc.table_name,
    kcu.column_name,
    ccu.table_name AS referenced_table,
    ccu.column_name AS referenced_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
  ON tc.constraint_name = kcu.constraint_name
 AND tc.constraint_schema = kcu.constraint_schema
JOIN information_schema.constraint_column_usage ccu
  ON ccu.constraint_name = tc.constraint_name
 AND ccu.constraint_schema = tc.constraint_schema
WHERE tc.constraint_type = 'FOREIGN KEY'
  AND tc.constraint_schema = 'public'
ORDER BY tc.table_name, kcu.column_name;
" > "$EXPORT_DIR/sql/reports/foreign-keys.tsv"

###############################################################################
# Export données métier non sensibles
###############################################################################

log "Export des données métier de référence"

for table in \
  restaurants \
  restaurant_settings \
  restaurant_closures
do
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
      -e PGPASSWORD="${POSTGRES_PASSWORD}" \
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
# Export n8n
###############################################################################

if [[ -n "$N8N_SERVICE" ]]; then
  log "Export des workflows n8n"

  "${COMPOSE[@]}" exec -T "$N8N_SERVICE" \
    sh -lc '
      rm -rf /tmp/booking-v2-n8n-export
      mkdir -p /tmp/booking-v2-n8n-export

      n8n export:workflow \
        --backup \
        --output=/tmp/booking-v2-n8n-export
    ' > "$EXPORT_DIR/logs/n8n-export.log" 2>&1 || {
      warn "La commande n8n export:workflow a échoué."
      warn "Consulte : $EXPORT_DIR/logs/n8n-export.log"
    }

  container_id="$("${COMPOSE[@]}" ps -q "$N8N_SERVICE" || true)"

  if [[ -n "$container_id" ]]; then
    docker cp \
      "${container_id}:/tmp/booking-v2-n8n-export/." \
      "$EXPORT_DIR/n8n/workflows/" 2>/dev/null || true
  fi
fi

###############################################################################
# Recherche Caddy
###############################################################################

log "Recherche des routes Caddy liées au client"

CADDY_SEARCH_PATHS=(
  "/opt"
  "/etc/caddy"
  "/root/saas_factory"
)

for search_path in "${CADDY_SEARCH_PATHS[@]}"; do
  [[ -d "$search_path" ]] || continue

  grep -RIl \
    --exclude-dir='.git' \
    --exclude='*.dump' \
    --exclude='*.log' \
    "$CLIENT_ID" \
    "$search_path" 2>/dev/null |
  while IFS= read -r file; do
    safe_name="$(
      printf '%s' "$file" |
        sed 's#^/##; s#/#__#g'
    )"

    cp -a "$file" "$EXPORT_DIR/caddy/$safe_name" 2>/dev/null || true
  done
done

###############################################################################
# Manifeste
###############################################################################

log "Création du manifeste"

cat > "$EXPORT_DIR/meta/manifest.txt" <<MANIFEST
export_type=booking_v2_context
created_at=$(date --iso-8601=seconds)
client_id=$CLIENT_ID
client_dir=$CLIENT_DIR
postgres_service=$POSTGRES_SERVICE
postgres_database=$POSTGRES_DB
postgres_user=$POSTGRES_USER
n8n_service=${N8N_SERVICE:-not_detected}
allocation_mode=not_yet_configured
MANIFEST

cat > "$EXPORT_DIR/README.txt" <<'README'
EXPORT DE CONTEXTE BOOKING ENGINE V2
====================================

Cet export sert à construire la migration Booking Engine V2.

Contenu principal :

sql/schema/schema.sql
    Schéma PostgreSQL complet actuel.

sql/schema/booking-current.sql
    Schéma ciblé restaurants/réservations/fermetures.

sql/reports/booking-columns.tsv
    Types exacts des colonnes métier.

sql/reports/constraints.tsv
    Contraintes PostgreSQL existantes.

sql/reports/foreign-keys.tsv
    Relations actuelles entre les tables.

sql/data/
    Données de configuration du restaurant.

n8n/workflows/
    Export des workflows n8n lorsque disponible.

docker/
    Configuration Docker actuelle sans secrets en clair.

Cet export n'applique aucune modification à la production.
README

###############################################################################
# Hashes
###############################################################################

find "$EXPORT_DIR" \
  -type f \
  ! -name SHA256SUMS \
  -print0 |
sort -z |
xargs -0 sha256sum \
  > "$EXPORT_DIR/SHA256SUMS"

###############################################################################
# Résumé
###############################################################################

success "Collecte terminée"

printf '\nExport créé :\n%s\n\n' "$EXPORT_DIR"

printf 'Fichiers importants :\n'
printf '  %s\n' "$EXPORT_DIR/sql/schema/schema.sql"
printf '  %s\n' "$EXPORT_DIR/sql/reports/booking-columns.tsv"
printf '  %s\n' "$EXPORT_DIR/sql/reports/constraints.tsv"
printf '  %s\n' "$EXPORT_DIR/sql/reports/foreign-keys.tsv"
printf '  %s\n' "$EXPORT_DIR/n8n/workflows"

printf '\nArborescence :\n'

if command -v tree >/dev/null 2>&1; then
  tree -a "$EXPORT_DIR"
else
  find "$EXPORT_DIR" -maxdepth 4 -print | sort
fi
