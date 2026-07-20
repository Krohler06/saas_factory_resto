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

UPDATE=false
DRY_RUN=false
SKIP_CADDY=false
SKIP_WORKFLOWS=false
ROTATE_SECRETS=false

usage() {
  cat <<'USAGE'
Usage:
  deploy-tenant.sh --tenant FILE [options]

Options:
  --factory FILE       Configuration globale.
  --update             Autorise la mise à jour d'un tenant existant.
  --dry-run            Génère et valide sans déployer.
  --skip-caddy         N'installe pas la route Caddy.
  --skip-workflows     N'importe pas les workflows n8n.
  --rotate-secrets     Régénère les secrets. Dangereux sur un tenant existant.
  -h, --help           Affiche cette aide.
USAGE
}

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
    --update)
      UPDATE=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --skip-caddy)
      SKIP_CADDY=true
      shift
      ;;
    --skip-workflows)
      SKIP_WORKFLOWS=true
      shift
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
  fatal "Factory absente : $FACTORY_FILE"

for command in docker python3 rsync curl tar; do
  command -v "$command" >/dev/null 2>&1 ||
    fatal "Commande absente : $command"
done

mapfile -t CONFIG < <(
  python3 - "$TENANT_FILE" "$FACTORY_FILE" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as stream:
    tenant = yaml.safe_load(stream)

with open(sys.argv[2], encoding="utf-8") as stream:
    factory_file = yaml.safe_load(stream)

factory = factory_file["factory"]
caddy = factory.get("caddy", {})
deployment = factory.get("deployment", {})

values = [
    tenant["tenant"]["client_id"],
    factory["clients_root"],
    factory["base_domain"],
    factory["edge_network"],
    str(bool(factory.get("create_edge_network", False))).lower(),
    str(bool(caddy.get("enabled", False))).lower(),
    str(caddy.get("container_name", "edge-caddy")),
    str(caddy.get("routes_host_dir", "")),
    str(caddy.get("container_config_path", "/etc/caddy/Caddyfile")),
    str(bool(caddy.get("reload", True))).lower(),
    str(int(deployment.get("wait_timeout_seconds", 180))),
    str(bool(deployment.get("import_workflows", True))).lower(),
    str(bool(deployment.get("smoke_test", True))).lower(),
]

print("\n".join(values))
PY
)

CLIENT_ID="${CONFIG[0]}"
CLIENTS_ROOT="${CONFIG[1]}"
BASE_DOMAIN="${CONFIG[2]}"
EDGE_NETWORK="${CONFIG[3]}"
CREATE_EDGE_NETWORK="${CONFIG[4]}"
CADDY_ENABLED="${CONFIG[5]}"
CADDY_CONTAINER="${CONFIG[6]}"
CADDY_ROUTES_HOST_DIR="${CONFIG[7]}"
CADDY_CONFIG_PATH="${CONFIG[8]}"
CADDY_RELOAD="${CONFIG[9]}"
WAIT_TIMEOUT="${CONFIG[10]}"
IMPORT_WORKFLOWS="${CONFIG[11]}"
SMOKE_TEST="${CONFIG[12]}"

TARGET_DIR="$CLIENTS_ROOT/$CLIENT_ID"
GENERATED_DIR="$FACTORY_DIR/generated/$CLIENT_ID"
BACKUP_DIR="$FACTORY_DIR/backups/deployments"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

if [[ -d "$TARGET_DIR" && "$UPDATE" != true ]]; then
  fatal "$TARGET_DIR existe déjà. Utiliser --update."
fi

if [[ "$ROTATE_SECRETS" == true && -d "$TARGET_DIR" ]]; then
  warn "Rotation de secrets demandée sur un tenant existant."
  warn "Les credentials n8n existants peuvent devenir illisibles."
fi

if [[ -f "$TARGET_DIR/.env" ]]; then
  mkdir -p "$GENERATED_DIR"
  cp -a "$TARGET_DIR/.env" "$GENERATED_DIR/.env"
fi

GENERATOR_ARGS=(
  --tenant "$TENANT_FILE"
  --factory "$FACTORY_FILE"
)

if [[ "$ROTATE_SECRETS" == true ]]; then
  GENERATOR_ARGS+=(--rotate-secrets)
fi

"$FACTORY_DIR/scripts/generate-tenant-infrastructure.sh" \
  "${GENERATOR_ARGS[@]}"

if [[ "$DRY_RUN" == true ]]; then
  ok "Dry-run terminé : $GENERATED_DIR"
  exit 0
fi

if ! docker network inspect "$EDGE_NETWORK" >/dev/null 2>&1; then
  if [[ "$CREATE_EDGE_NETWORK" == true ]]; then
    info "Création du réseau externe $EDGE_NETWORK"
    docker network create "$EDGE_NETWORK" >/dev/null
  else
    fatal "Réseau externe absent : $EDGE_NETWORK"
  fi
fi

mkdir -p "$BACKUP_DIR"

if [[ -d "$TARGET_DIR" ]]; then
  BACKUP_FILE="$BACKUP_DIR/${CLIENT_ID}_${TIMESTAMP}.tar.gz"

  info "Sauvegarde de la configuration existante"
  tar -C "$CLIENTS_ROOT" \
    -czf "$BACKUP_FILE" \
    "$CLIENT_ID"

  chmod 600 "$BACKUP_FILE"
  ok "Sauvegarde : $BACKUP_FILE"
fi

mkdir -p "$TARGET_DIR"

rsync -a --delete \
  "$GENERATED_DIR/" \
  "$TARGET_DIR/"

chmod 700 "$TARGET_DIR"
chmod 600 "$TARGET_DIR/.env"

cd "$TARGET_DIR"

docker compose \
  --env-file .env \
  -f docker-compose.yml \
  config \
  >/dev/null

wait_for_health() {
  local container="$1"
  local timeout="$2"
  local started
  local status

  started="$(date +%s)"

  while true; do
    status="$(
      docker inspect \
        --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        "$container" 2>/dev/null || true
    )"

    case "$status" in
      healthy|running)
        return 0
        ;;
      unhealthy|exited|dead)
        fatal "$container est dans l'état $status"
        ;;
    esac

    if (( $(date +%s) - started >= timeout )); then
      fatal "Timeout en attendant $container, état=$status"
    fi

    sleep 3
  done
}

info "Démarrage de PostgreSQL"

docker compose \
  --env-file .env \
  -f docker-compose.yml \
  up -d postgres

wait_for_health "${CLIENT_ID}_postgres" "$WAIT_TIMEOUT"

set -a
# shellcheck disable=SC1091
source .env
set +a

info "Application des migrations et seeds"

while IFS= read -r sql_file; do
  info "SQL : $(basename "$sql_file")"

  docker compose \
    --env-file .env \
    -f docker-compose.yml \
    exec -T \
    -e PGPASSWORD="$POSTGRES_PASSWORD" \
    postgres \
    psql \
    -v ON_ERROR_STOP=1 \
    -U "$POSTGRES_USER" \
    -d "$POSTGRES_DB" \
    < "$sql_file"
done < <(
  find "$TARGET_DIR/sql" \
    -maxdepth 1 \
    -type f \
    -name '*.sql' \
    | sort
)

info "Démarrage de n8n"

docker compose \
  --env-file .env \
  -f docker-compose.yml \
  up -d n8n

wait_for_health "${CLIENT_ID}_n8n" "$WAIT_TIMEOUT"

workflow_count="$(
  find "$TARGET_DIR/n8n/workflows" \
    -maxdepth 1 \
    -type f \
    -name '*.json' \
    | wc -l
)"

if [[ "$SKIP_WORKFLOWS" != true \
      && "$IMPORT_WORKFLOWS" == true \
      && "$workflow_count" -gt 0 ]]; then
  info "Import de $workflow_count workflow(s) n8n"

  docker compose \
    --env-file .env \
    -f docker-compose.yml \
    exec -T n8n \
    n8n import:workflow \
    --separate \
    --input=/import/workflows
else
  warn "Aucun workflow importé."
fi

CADDY_ROUTE_BACKUP=""

restore_caddy_route() {
  local destination="$1"

  if [[ -n "$CADDY_ROUTE_BACKUP" \
        && -f "$CADDY_ROUTE_BACKUP" ]]; then
    cp -a "$CADDY_ROUTE_BACKUP" "$destination"
  else
    rm -f "$destination"
  fi
}

if [[ "$SKIP_CADDY" != true && "$CADDY_ENABLED" == true ]]; then
  [[ -n "$CADDY_ROUTES_HOST_DIR" ]] ||
    fatal "factory.caddy.routes_host_dir est vide."

  [[ -d "$CADDY_ROUTES_HOST_DIR" ]] ||
    fatal "Répertoire Caddy absent : $CADDY_ROUTES_HOST_DIR"

  CADDY_DESTINATION="$CADDY_ROUTES_HOST_DIR/$CLIENT_ID.caddy"

  if [[ -f "$CADDY_DESTINATION" ]]; then
    CADDY_ROUTE_BACKUP="$BACKUP_DIR/${CLIENT_ID}_${TIMESTAMP}.caddy"
    cp -a "$CADDY_DESTINATION" "$CADDY_ROUTE_BACKUP"
  fi

  cp -a \
    "$TARGET_DIR/caddy/$CLIENT_ID.caddy" \
    "$CADDY_DESTINATION"

  info "Validation Caddy"

  if ! docker exec "$CADDY_CONTAINER" \
    caddy validate \
    --config "$CADDY_CONFIG_PATH"
  then
    restore_caddy_route "$CADDY_DESTINATION"
    fatal "Validation Caddy échouée. Route restaurée."
  fi

  if [[ "$CADDY_RELOAD" == true ]]; then
    info "Rechargement Caddy"

    if ! docker exec "$CADDY_CONTAINER" \
      caddy reload \
      --config "$CADDY_CONFIG_PATH"
    then
      restore_caddy_route "$CADDY_DESTINATION"
      docker exec "$CADDY_CONTAINER" \
        caddy reload \
        --config "$CADDY_CONFIG_PATH" \
        >/dev/null 2>&1 || true

      fatal "Reload Caddy échoué. Route restaurée."
    fi
  fi
fi

if [[ "$SMOKE_TEST" == true && "$SKIP_CADDY" != true ]]; then
  info "Smoke test HTTPS"

  PUBLIC_URL="https://${BASE_DOMAIN}/${CLIENT_ID}/"
  success=false

  for _ in $(seq 1 20); do
    if curl \
      --fail \
      --silent \
      --show-error \
      --location \
      --max-time 10 \
      "$PUBLIC_URL" \
      >/dev/null
    then
      success=true
      break
    fi

    sleep 3
  done

  if [[ "$success" != true ]]; then
    warn "Le smoke test n'a pas obtenu de réponse valide : $PUBLIC_URL"
  else
    ok "URL accessible : $PUBLIC_URL"
  fi
fi

ok "Déploiement terminé : $CLIENT_ID"
ok "Répertoire : $TARGET_DIR"

