#!/usr/bin/env bash

set -Eeuo pipefail

CLIENTS_ROOT="${CLIENTS_ROOT:-/opt/clients}"

usage() {
  cat <<'USAGE'
Usage:
  tenant-compose.sh CLIENT_ID COMMANDE_COMPOSE...

Exemples:
  tenant-compose.sh little_africa_nice ps
  tenant-compose.sh la_trattoria up -d
  tenant-compose.sh little_africa_nice up -d --build --no-deps manager
USAGE
}

fatal() {
  printf '[ERREUR] %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 2 ]] || {
  usage
  exit 1
}

CLIENT_ID="$1"
shift

CLIENT_DIR="$CLIENTS_ROOT/$CLIENT_ID"
ENV_FILE="$CLIENT_DIR/.env"
BASE_COMPOSE="$CLIENT_DIR/docker-compose.yml"
MANAGER_COMPOSE="$CLIENT_DIR/docker-compose.manager.yml"

[[ -d "$CLIENT_DIR" ]] ||
  fatal "Tenant absent : $CLIENT_DIR"

[[ -f "$ENV_FILE" ]] ||
  fatal "Fichier .env absent : $ENV_FILE"

[[ -f "$BASE_COMPOSE" ]] ||
  fatal "Compose principal absent : $BASE_COMPOSE"

COMPOSE_FILES=(
  -f "$BASE_COMPOSE"
)

if [[ -f "$MANAGER_COMPOSE" ]]; then
  COMPOSE_FILES+=(
    -f "$MANAGER_COMPOSE"
  )
fi

exec env -i \
  HOME="${HOME:-/root}" \
  PATH="$PATH" \
  docker compose \
    -p "$CLIENT_ID" \
    --project-directory "$CLIENT_DIR" \
    --env-file "$ENV_FILE" \
    "${COMPOSE_FILES[@]}" \
    "$@"
