#!/usr/bin/env bash
set -Eeuo pipefail

WEBHOOK_URL="${1:?Usage: smoke_retell_webhook.sh https://domain/client/webhook/retell-voice-function}"
SLUG="${2:-demo-restaurant}"

echo
echo "== get_restaurant_context =="
curl -sS -X POST "$WEBHOOK_URL"
-H 'Content-Type: application/json'
-d "{
"action": "get_restaurant_context",
"source": "retell_voice",
"restaurant_slug": "$SLUG",
"conversation_id": "smoke-context-001"
}" | jq

echo
echo "== resolve_reservation_datetime =="
curl -sS -X POST "$WEBHOOK_URL"
-H 'Content-Type: application/json'
-d "{
"action": "resolve_reservation_datetime",
"source": "retell_voice",
"restaurant_slug": "$SLUG",
"date_text": "mercredi prochain",
"time_text": "midi trente",
"current_datetime": "2026-07-18T23:16:00+02:00",
"restaurant_timezone": "Europe/Paris",
"conversation_id": "smoke-resolve-001"
}" | jq

echo
echo "== check_availability =="
curl -sS -X POST "$WEBHOOK_URL"
-H 'Content-Type: application/json'
-d "{
"action": "check_availability",
"source": "retell_voice",
"restaurant_slug": "$SLUG",
"requested_datetime": "2026-07-22T12:30:00+02:00",
"party_size": 3,
"conversation_id": "smoke-check-001"
}" | jq

echo
echo "== create_reservation without name should fail =="
curl -sS -X POST "$WEBHOOK_URL"
-H 'Content-Type: application/json'
-d "{
"action": "create_reservation",
"source": "retell_voice",
"restaurant_slug": "$SLUG",
"requested_datetime": "2026-07-22T12:30:00+02:00",
"party_size": 3,
"customer_confirmed": true,
"conversation_id": "smoke-create-no-name-001"
}" | jq
