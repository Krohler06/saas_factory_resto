#!/usr/bin/env bash
set -Eeuo pipefail

EXPORT_DIR="${1:?Usage: promote-export-to-template.sh /root/saas_factory/exports/<export_dir>}"
BASE="/root/saas_factory"
TPL="$BASE/template"

if [ ! -d "$EXPORT_DIR" ]; then
echo "ERREUR: dossier export introuvable: $EXPORT_DIR" >&2
exit 1
fi

mkdir -p \
"$TPL/docker" \
"$TPL/env" \
"$TPL/sql/migrations" \
"$TPL/sql/seeds/reference" \
"$TPL/n8n/workflows/separate" \
"$TPL/n8n/credentials" \
"$TPL/caddy" \
"$TPL/tests" \
"$TPL/retell" \

echo "Promotion export vers template : $EXPORT_DIR"

if [ -f "$EXPORT_DIR/docker/docker-compose.yml" ]; then
cp "$EXPORT_DIR/docker/docker-compose.yml" "$TPL/docker/docker-compose.exported.reference.yml"
fi

if [ -f "$EXPORT_DIR/docker/docker-compose.resolved.yml" ]; then
cp "$EXPORT_DIR/docker/docker-compose.resolved.yml" "$TPL/docker/docker-compose.resolved.reference.yml"
fi

if [ -f "$EXPORT_DIR/sql/schema/schema.sql" ]; then
cp "$EXPORT_DIR/sql/schema/schema.sql" "$TPL/sql/migrations/001_schema_current.sql"
fi

if [ -f "$EXPORT_DIR/sql/schema/columns.tsv" ]; then
cp "$EXPORT_DIR/sql/schema/columns.tsv" "$TPL/sql/migrations/columns.reference.tsv"
fi

if [ -f "$EXPORT_DIR/sql/schema/tables.txt" ]; then
cp "$EXPORT_DIR/sql/schema/tables.txt" "$TPL/sql/migrations/tables.reference.txt"
fi

if [ -d "$EXPORT_DIR/sql/data" ]; then
cp -a "$EXPORT_DIR/sql/data/." "$TPL/sql/seeds/reference/" || true
fi

if [ -f "$EXPORT_DIR/n8n/workflows/workflows.all.json" ]; then
cp "$EXPORT_DIR/n8n/workflows/workflows.all.json" "$TPL/n8n/workflows/workflows.all.json"
fi

if [ -d "$EXPORT_DIR/n8n/workflows/separate" ]; then
rm -rf "$TPL/n8n/workflows/separate"
mkdir -p "$TPL/n8n/workflows/separate"
cp -a "$EXPORT_DIR/n8n/workflows/separate/." "$TPL/n8n/workflows/separate/"
fi

if [ -f "$EXPORT_DIR/caddy/routes_grep.txt" ]; then
cp "$EXPORT_DIR/caddy/routes_grep.txt" "$TPL/caddy/routes.reference.txt"
fi

if [ -f "$EXPORT_DIR/meta/tenant_manifest.json" ]; then
cp "$EXPORT_DIR/meta/tenant_manifest.json" "$TPL/tenant_manifest.reference.json"
fi

cat > "$TPL/PROMOTED_FROM.txt" <<EOF2
Promoted from: $EXPORT_DIR
Promoted at: $(date -Iseconds)
EOF2

echo "OK: template mis à jour dans $TPL"
echo
echo "À vérifier :"
echo " tree -a $TPL"
echo " bash $BASE/scripts/scan-secrets.sh"
