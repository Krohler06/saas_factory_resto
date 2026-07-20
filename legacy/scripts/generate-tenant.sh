#!/usr/bin/env bash
set -Eeuo pipefail

FACTORY_DIR="${FACTORY_DIR:-/root/saas_factory}"
TENANT_FILE="${1:-}"

fatal() {
  printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"
}

ok() {
  printf '\033[1;32m[OK]\033[0m %s\n' "$*"
}

[[ -n "$TENANT_FILE" ]] || fatal "Usage : generate-tenant.sh /chemin/tenant.yml"
[[ -f "$TENANT_FILE" ]] || fatal "Fichier absent : $TENANT_FILE"

VALIDATOR="$FACTORY_DIR/scripts/validate-tenant.py"
SEED_GENERATOR="$FACTORY_DIR/scripts/generate-booking-v2-seed.py"

[[ -x "$VALIDATOR" ]] || fatal "Validateur absent : $VALIDATOR"
[[ -x "$SEED_GENERATOR" ]] || fatal "Générateur SQL absent : $SEED_GENERATOR"

info "Validation de $TENANT_FILE"
"$VALIDATOR" "$TENANT_FILE"

readarray -t META < <(python3 - "$TENANT_FILE" <<'PY'
import sys, yaml
with open(sys.argv[1], encoding='utf-8') as f:
    cfg=yaml.safe_load(f)
print(cfg['tenant']['client_id'])
print(cfg['tenant']['restaurant_slug'])
print(cfg['restaurant']['timezone'])
print(cfg['booking_engine']['allocation_mode'])
PY
)

CLIENT_ID="${META[0]}"
RESTAURANT_SLUG="${META[1]}"
TIMEZONE="${META[2]}"
ALLOCATION_MODE="${META[3]}"
GENERATED_DIR="$FACTORY_DIR/generated/$CLIENT_ID"
SQL_DIR="$GENERATED_DIR/sql"

rm -rf "$GENERATED_DIR"
mkdir -p "$SQL_DIR" "$GENERATED_DIR/meta"

info "Génération du seed SQL"
"$SEED_GENERATOR" \
  "$TENANT_FILE" \
  "$SQL_DIR/010-booking-engine-v2-seed.sql"

cp -a "$TENANT_FILE" "$GENERATED_DIR/tenant.snapshot.yml"

cat > "$GENERATED_DIR/meta/manifest.json" <<EOF
{
  "format_version": 1,
  "client_id": "$CLIENT_ID",
  "restaurant_slug": "$RESTAURANT_SLUG",
  "timezone": "$TIMEZONE",
  "allocation_mode": "$ALLOCATION_MODE",
  "generated_at": "$(date --iso-8601=seconds)",
  "files": {
    "tenant_snapshot": "tenant.snapshot.yml",
    "booking_seed": "sql/010-booking-engine-v2-seed.sql"
  }
}
EOF

(
  cd "$GENERATED_DIR"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
)

ok "Génération terminée : $GENERATED_DIR"
printf '\nFichiers :\n'
find "$GENERATED_DIR" -maxdepth 3 -type f -printf '  %p\n' | sort

