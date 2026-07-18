#!/usr/bin/env bash
set -Eeuo pipefail

CLIENT_DIR="${1:?Usage: test-tenant.sh /opt/clients/<client_id>}"

cd "$CLIENT_DIR"
set -a
source .env
set +a

WEBHOOK="${WEBHOOK_URL}webhook/retell-voice-function"

if [ -x "$CLIENT_DIR/tests/smoke_retell_webhook.sh" ]; then
"$CLIENT_DIR/tests/smoke_retell_webhook.sh" "$WEBHOOK" "$RESTAURANT_SLUG"
else
echo "Script smoke test introuvable"
exit 1
fi
