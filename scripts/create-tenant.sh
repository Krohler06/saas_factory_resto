#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/root/saas_factory"
TEMPLATE="$BASE/template"
TARGET_BASE="/opt/clients"

CLIENT_ID=""
RESTAURANT_SLUG=""
RESTAURANT_NAME=""
BASE_DOMAIN=""
TLS_EMAIL=""

while [ $# -gt 0 ]; do
case "$1" in
--client-id)
CLIENT_ID="${2:?}"; shift 2 ;;
--restaurant-slug)
RESTAURANT_SLUG="${2:?}"; shift 2 ;;
--restaurant-name)
RESTAURANT_NAME="${2:?}"; shift 2 ;;
--base-domain)
BASE_DOMAIN="${2:?}"; shift 2 ;;
--tls-email)
TLS_EMAIL="${2:?}"; shift 2 ;;
--target-base)
TARGET_BASE="${2:?}"; shift 2 ;;
*)
echo "Argument inconnu: $1" >&2
exit 1 ;;
esac
done

if [ -z "$CLIENT_ID" ] || [ -z "$RESTAURANT_SLUG" ] || [ -z "$RESTAURANT_NAME" ] || [ -z "$BASE_DOMAIN" ] || [ -z "$TLS_EMAIL" ]; then
cat >&2 <<USAGE
Usage:
create-tenant.sh \
--client-id demo_restaurant_01 \
--restaurant-slug demo-restaurant \
--restaurant-name "Restaurant Démo" \
--base-domain __BASE_DOMAIN__ \
--tls-email admin@example.com
USAGE
exit 1
fi

CLIENT_DIR="$TARGET_BASE/$CLIENT_ID"

if [ -e "$CLIENT_DIR" ]; then
echo "ERREUR: le dossier client existe déjà: $CLIENT_DIR" >&2
exit 1
fi

POSTGRES_DB="booking_${CLIENT_ID}"
POSTGRES_USER="booking_user"
POSTGRES_PASSWORD="$(openssl rand -base64 36 | tr -d '\n' | tr '/+' 'Aa' | cut -c1-32)"
N8N_ENCRYPTION_KEY="$(openssl rand -hex 32)"
N8N_USER_MANAGEMENT_JWT_SECRET="$(openssl rand -hex 32)"

mkdir -p "$CLIENT_DIR"/{data/n8n,workflows,sql/migrations,sql/seeds,caddy,tests}

cp "$TEMPLATE/docker/docker-compose.yml" "$CLIENT_DIR/docker-compose.yml"

if [ -d "$TEMPLATE/n8n/workflows" ]; then
cp -a "$TEMPLATE/n8n/workflows/." "$CLIENT_DIR/workflows/" || true
fi

if [ -d "$TEMPLATE/sql/migrations" ]; then
cp -a "$TEMPLATE/sql/migrations/." "$CLIENT_DIR/sql/migrations/" || true
fi

if [ -d "$TEMPLATE/sql/seeds" ]; then
cp -a "$TEMPLATE/sql/seeds/." "$CLIENT_DIR/sql/seeds/" || true
fi

cat > "$CLIENT_DIR/.env" <<ENV
CLIENT_ID=$CLIENT_ID
BASE_DOMAIN=$BASE_DOMAIN
TLS_EMAIL=$TLS_EMAIL

POSTGRES_DB=$POSTGRES_DB
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD

N8N_HOST=$BASE_DOMAIN
N8N_PROTOCOL=https
N8N_PATH=/$CLIENT_ID/
N8N_EDITOR_BASE_URL=https://$BASE_DOMAIN/$CLIENT_ID/
WEBHOOK_URL=https://$BASE_DOMAIN/$CLIENT_ID/

N8N_ENCRYPTION_KEY=$N8N_ENCRYPTION_KEY
N8N_USER_MANAGEMENT_JWT_SECRET=$N8N_USER_MANAGEMENT_JWT_SECRET

RESTAURANT_SLUG=$RESTAURANT_SLUG
RESTAURANT_NAME=$RESTAURANT_NAME
RESTAURANT_TIMEZONE=Europe/Paris

DEFAULT_MEAL_DURATION_MINUTES=120
CLEANING_BUFFER_MINUTES=15
GRACE_DELAY_MINUTES=10
MAX_PARTY_SIZE=12
ENV

sed
-e "s#CLIENT_ID#$CLIENT_ID#g"
-e "s#RESTAURANT_SLUG#$RESTAURANT_SLUG#g"
-e "s#RESTAURANT_NAME#$RESTAURANT_NAME#g"
-e "s#BASE_DOMAIN#$BASE_DOMAIN#g"
"$TEMPLATE/caddy/client-route.caddy.template" \

"$CLIENT_DIR/caddy/${CLIENT_ID}.caddy"

if [ -f "$TEMPLATE/sql/seeds/seed-restaurant.sql.template" ]; then
sed
-e "s#RESTAURANT_SLUG#$RESTAURANT_SLUG#g"
-e "s#RESTAURANT_NAME#$RESTAURANT_NAME#g"
"$TEMPLATE/sql/seeds/seed-restaurant.sql.template"
> "$CLIENT_DIR/sql/seeds/seed-restaurant.sql"
fi

cp "$TEMPLATE/tests/smoke_retell_webhook.sh" "$CLIENT_DIR/tests/smoke_retell_webhook.sh" 2>/dev/null || true
chmod +x "$CLIENT_DIR/tests/"*.sh 2>/dev/null || true

echo
echo "Client créé : $CLIENT_DIR"
echo
echo "Prochaines étapes :"
echo " cd $CLIENT_DIR"
echo " docker compose up -d postgres"
echo " appliquer le schéma SQL"
echo " docker compose up -d n8n"
echo " importer les workflows"
echo
echo "Webhook Retell :"
echo " https://$BASE_DOMAIN/$CLIENT_ID/webhook/retell-voice-function"
echo
echo "Route Caddy générée :"
echo " $CLIENT_DIR/caddy/${CLIENT_ID}.caddy"
