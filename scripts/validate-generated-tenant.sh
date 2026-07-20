#!/usr/bin/env bash

set -Eeuo pipefail

# SAAS_FACTORY_TENANT_ENV_GUARD
#
# Docker Compose donne priorité aux variables déjà exportées dans le shell.
# On supprime donc toutes les variables propres à un tenant avant de lire
# le fichier .env généré pour le tenant courant.
unset \
  COMPOSE_PROJECT_NAME \
  CLIENT_ID \
  RESTAURANT_SLUG \
  TENANT_PATH \
  BASE_DOMAIN \
  EDGE_NETWORK \
  TIMEZONE \
  POSTGRES_IMAGE \
  POSTGRES_DB \
  POSTGRES_USER \
  POSTGRES_PASSWORD \
  N8N_IMAGE \
  N8N_LOG_LEVEL \
  N8N_ENCRYPTION_KEY \
  2>/dev/null || true


GENERATED_DIR="${1:-}"

fatal() {
  printf '[ERREUR] %s\n' "$*" >&2
  exit 1
}

[[ -n "$GENERATED_DIR" ]] ||
  fatal "Usage : validate-generated-tenant.sh DOSSIER_GENERE"

[[ -d "$GENERATED_DIR" ]] ||
  fatal "Dossier absent : $GENERATED_DIR"

required_files=(
  ".env"
  "docker-compose.yml"
  "tenant.snapshot.yml"
  "meta/manifest.json"
  "n8n/credentials/postgres.json"
  "sql/010-booking-engine-v2-seed.sql"
  "SHA256SUMS"
)

for file in "${required_files[@]}"; do
  [[ -f "$GENERATED_DIR/$file" ]] ||
    fatal "Fichier obligatoire absent : $file"
done

python3 -m json.tool \
  "$GENERATED_DIR/meta/manifest.json" \
  >/dev/null

if grep -RInE \
  '@@[A-Z0-9_]+@@|CHANGE_ME|__GENERATED_SECRET__' \
  "$GENERATED_DIR" \
  --exclude='SHA256SUMS'
then
  fatal "Variables non résolues détectées."
fi

docker compose \
  --env-file "$GENERATED_DIR/.env" \
  -f "$GENERATED_DIR/docker-compose.yml" \
  config \
  >/dev/null

while IFS= read -r workflow; do
  python3 -m json.tool "$workflow" >/dev/null
done < <(
  find "$GENERATED_DIR/n8n/workflows" \
    -maxdepth 1 \
    -type f \
    -name '*.json' \
    | sort
)

(
  cd "$GENERATED_DIR"
  sha256sum -c SHA256SUMS >/dev/null
)

permissions="$(stat -c '%a' "$GENERATED_DIR/.env")"

[[ "$permissions" == "600" ]] ||
  fatal ".env doit être en 600, valeur actuelle : $permissions"

mapfile -t duplicate_sql_versions < <(
  find "$GENERATED_DIR/sql" \
    -maxdepth 1 \
    -type f \
    -name '[0-9][0-9][0-9]*.sql' \
    -printf '%f\n' |
  sed -E 's/^([0-9]{3}).*/\1/' |
  sort |
  uniq -d
)

if [[ "${#duplicate_sql_versions[@]}" -gt 0 ]]; then
  printf '[ERREUR] Numéros SQL dupliqués :\n' >&2
  printf '  - %s\n' "${duplicate_sql_versions[@]}" >&2

  printf '\nFichiers concernés :\n' >&2

  for version in "${duplicate_sql_versions[@]}"; do
    find "$GENERATED_DIR/sql" \
      -maxdepth 1 \
      -type f \
      -name "${version}*.sql" \
      -printf '  - %f\n' >&2
  done

  fatal "Chaque fichier SQL doit avoir un numéro unique."
fi

printf '[OK] Rendu valide : %s\n' "$GENERATED_DIR"


while IFS= read -r credential; do
  python3 -m json.tool "$credential" >/dev/null
done < <(
  find "$GENERATED_DIR/n8n/credentials" \
    -maxdepth 1 \
    -type f \
    -name '*.json' \
    | sort
)
