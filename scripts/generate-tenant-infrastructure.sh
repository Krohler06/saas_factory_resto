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

umask 077

FACTORY_DIR="${FACTORY_DIR:-/root/saas_factory}"
TENANT_FILE=""
FACTORY_FILE="${FACTORY_FILE:-$FACTORY_DIR/config/factory.yml}"
ROTATE_SECRETS=false

usage() {
  cat <<'USAGE'
Usage:
  generate-tenant-infrastructure.sh --tenant FILE [options]

Options:
  --factory FILE       Configuration globale de la factory.
  --rotate-secrets     Régénère le mot de passe PostgreSQL et la clé n8n.
  -h, --help           Affiche cette aide.
USAGE
}

fatal() {
  printf '[ERREUR] %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant)
      TENANT_FILE="${2:-}"
      shift 2
      ;;
    --factory)
      FACTORY_FILE="${2:-}"
      shift 2
      ;;
    --rotate-secrets)
      ROTATE_SECRETS=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fatal "Argument inconnu : $1"
      ;;
  esac
done

[[ -n "$TENANT_FILE" ]] || {
  usage
  fatal "--tenant est obligatoire."
}

[[ -f "$TENANT_FILE" ]] ||
  fatal "Tenant absent : $TENANT_FILE"

[[ -f "$FACTORY_FILE" ]] ||
  fatal "Configuration factory absente : $FACTORY_FILE"

for command in python3 sha256sum docker; do
  command -v "$command" >/dev/null 2>&1 ||
    fatal "Commande absente : $command"
done

VALIDATOR="$FACTORY_DIR/scripts/validate-tenant.py"
BOOTSTRAP_GENERATOR="$FACTORY_DIR/scripts/generate-tenant-bootstrap.py"
SEED_GENERATOR="$FACTORY_DIR/scripts/generate-booking-v2-seed.py"
RENDERER="$FACTORY_DIR/scripts/render-tenant-infrastructure.py"
GENERATED_VALIDATOR="$FACTORY_DIR/scripts/validate-generated-tenant.sh"

[[ -x "$VALIDATOR" ]] || fatal "Validateur absent : $VALIDATOR"
[[ -x "$BOOTSTRAP_GENERATOR" ]] || fatal "Générateur bootstrap absent : $BOOTSTRAP_GENERATOR"
[[ -x "$SEED_GENERATOR" ]] || fatal "Générateur SQL absent : $SEED_GENERATOR"
[[ -x "$RENDERER" ]] || fatal "Renderer absent : $RENDERER"
[[ -x "$GENERATED_VALIDATOR" ]] ||
  fatal "Validateur de rendu absent : $GENERATED_VALIDATOR"

"$VALIDATOR" "$TENANT_FILE"

CLIENT_ID="$(
  python3 - "$TENANT_FILE" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    data = yaml.safe_load(stream)

print(data["tenant"]["client_id"])
PY
)"

[[ -n "$CLIENT_ID" ]] ||
  fatal "client_id introuvable."

OUTPUT_DIR="$FACTORY_DIR/generated/$CLIENT_ID"
mkdir -p "$OUTPUT_DIR"

RENDER_ARGS=(
  "$TENANT_FILE"
  "$FACTORY_FILE"
  "$OUTPUT_DIR"
  --template-root "$FACTORY_DIR/template"
  --force
)

if [[ "$ROTATE_SECRETS" == true ]]; then
  RENDER_ARGS+=(--rotate-secrets)
fi

"$RENDERER" "${RENDER_ARGS[@]}"

"$BOOTSTRAP_GENERATOR" \
  "$TENANT_FILE" \
  "$OUTPUT_DIR/sql/005-tenant-bootstrap.sql"

"$SEED_GENERATOR" \
  "$TENANT_FILE" \
  "$OUTPUT_DIR/sql/010-booking-engine-v2-seed.sql"

(
  cd "$OUTPUT_DIR"
  rm -f SHA256SUMS

  find . \
    -type f \
    ! -name SHA256SUMS \
    -print0 |
  sort -z |
  xargs -0 sha256sum > SHA256SUMS
)

"$GENERATED_VALIDATOR" "$OUTPUT_DIR"

printf '\n[OK] Tenant généré : %s\n' "$OUTPUT_DIR"
printf '[OK] Manifest : %s\n' "$OUTPUT_DIR/meta/manifest.json"
printf '[OK] Compose : %s\n' "$OUTPUT_DIR/docker-compose.yml"
printf '[OK] Route Caddy : %s\n' "$OUTPUT_DIR/caddy/$CLIENT_ID.caddy"

