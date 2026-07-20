#!/usr/bin/env bash
set -Eeuo pipefail

FACTORY_DIR="${FACTORY_DIR:-/root/saas_factory}"
EXPORT_DIR="${1:-}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
GENERATED_ROOT="$FACTORY_DIR/generated/booking-engine-v2"
GENERATED_DIR="$GENERATED_ROOT/$TIMESTAMP"
BASELINE_DIR="$FACTORY_DIR/baseline/booking-engine-v2"

info(){ printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
fatal(){ printf '\033[1;31m[ERREUR]\033[0m %s\n' "$*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fatal "Commande absente : $1"; }

for cmd in jq awk grep sed find sort cp ln; do need "$cmd"; done

if [[ -z "$EXPORT_DIR" ]]; then
  EXPORT_DIR="$(find "$FACTORY_DIR/exports" -mindepth 1 -maxdepth 1 -type d -name '*_booking_v2_context_*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
fi

[[ -n "$EXPORT_DIR" ]] || fatal "Aucun export Booking V2 trouvé"
[[ -d "$EXPORT_DIR" ]] || fatal "Export introuvable : $EXPORT_DIR"

SCHEMA_FILE="$EXPORT_DIR/sql/schema/schema.sql"
TABLES_REPORT="$EXPORT_DIR/sql/reports/tables.txt"
WORKFLOWS_DIR="$EXPORT_DIR/n8n/workflows"

[[ -f "$SCHEMA_FILE" ]] || fatal "Schéma absent : $SCHEMA_FILE"
[[ -d "$WORKFLOWS_DIR" ]] || fatal "Workflows absents : $WORKFLOWS_DIR"

mkdir -p \
  "$FACTORY_DIR/docs" \
  "$FACTORY_DIR/tenants/examples" \
  "$FACTORY_DIR/template/sql/migrations" \
  "$GENERATED_DIR/reports" \
  "$GENERATED_DIR/workflows" \
  "$BASELINE_DIR/sql" \
  "$BASELINE_DIR/workflows"

info "Copie de la baseline"
cp -a "$SCHEMA_FILE" "$BASELINE_DIR/sql/schema-v1.sql"
for f in columns.tsv booking-columns.tsv constraints.tsv indexes.tsv foreign-keys.tsv; do
  [[ -f "$EXPORT_DIR/sql/reports/$f" ]] && cp -a "$EXPORT_DIR/sql/reports/$f" "$BASELINE_DIR/sql/${f%.tsv}-v1.tsv"
done
find "$WORKFLOWS_DIR" -maxdepth 1 -type f -name '*.json' -exec cp -a {} "$BASELINE_DIR/workflows/" \;

info "Analyse des tables"
CURRENT="$GENERATED_DIR/reports/current-tables.txt"
if [[ -f "$TABLES_REPORT" ]]; then
  grep -Ev '^(table_name|\([0-9]+ rows?\)|$)' "$TABLES_REPORT" | tr -d '\r' | sort -u > "$CURRENT"
else
  grep -E '^CREATE TABLE public\.' "$SCHEMA_FILE" | sed -E 's/^CREATE TABLE public\.([^ ]+).*/\1/' | sort -u > "$CURRENT"
fi

REQUIRED="$GENERATED_DIR/reports/required-v2-tables.txt"
cat > "$REQUIRED" <<'TABLES'
restaurant_service_definitions
restaurant_service_hours
restaurant_areas
restaurant_area_aliases
restaurant_tables
reservation_tables
TABLES

GAP="$GENERATED_DIR/reports/table-gap.tsv"
printf 'table_name\tstatus\n' > "$GAP"
while IFS= read -r table; do
  [[ -z "$table" ]] && continue
  if grep -Fxq "$table" "$CURRENT"; then status=PRESENT; else status=MISSING; fi
  printf '%s\t%s\n' "$table" "$status" >> "$GAP"
done < "$REQUIRED"

info "Analyse des workflows n8n"
WF="$GENERATED_DIR/reports/workflows.tsv"
WH="$GENERATED_DIR/reports/webhooks.tsv"
PG="$GENERATED_DIR/reports/postgres-nodes.tsv"
LOGIC="$GENERATED_DIR/reports/logic-nodes.tsv"

printf 'workflow_name\tworkflow_id\tactive\tnode_count\tfile\n' > "$WF"
printf 'workflow_name\tfile\tnode_name\thttp_method\tpath\tresponse_mode\twebhook_id\n' > "$WH"
printf 'workflow_name\tfile\tnode_name\toperation\tquery_preview\n' > "$PG"
printf 'workflow_name\tfile\tnode_name\tnode_type\n' > "$LOGIC"

while IFS= read -r file; do
  name="$(basename "$file")"

  jq -r --arg file "$name" '
    (if type=="array" then .[] else . end) |
    [(.name//"unnamed"),(.id//""),((.active//false)|tostring),(((.nodes//[])|length)|tostring),$file] | @tsv
  ' "$file" >> "$WF"

  jq -r --arg file "$name" '
    (if type=="array" then .[] else . end) as $w |
    ($w.nodes//[])[]? |
    select(((.type//"")|ascii_downcase|contains("webhook")) and (((.type//"")|ascii_downcase|contains("respondtowebhook"))|not)) |
    [($w.name//"unnamed"),$file,(.name//""),(.parameters.httpMethod//.parameters.method//"GET"|tostring),(.parameters.path//""|tostring),(.parameters.responseMode//""|tostring),(.webhookId//""|tostring)] | @tsv
  ' "$file" >> "$WH"

  jq -r --arg file "$name" '
    (if type=="array" then .[] else . end) as $w |
    ($w.nodes//[])[]? |
    select((.type//"")|test("postgres";"i")) |
    [($w.name//"unnamed"),$file,(.name//""),(.parameters.operation//.parameters.resource//""|tostring),((.parameters.query//.parameters.sql//.parameters.additionalFields.query//"")|tostring|gsub("[\\r\\n\\t]+";" ")|.[0:700])] | @tsv
  ' "$file" >> "$PG"

  jq -r --arg file "$name" '
    (if type=="array" then .[] else . end) as $w |
    ($w.nodes//[])[]? |
    select(((.type//"")|test("code|function";"i")) or ((.name//"")|test("availability|reservation|service|capacity|closure|date|time|booking|table|area";"i"))) |
    [($w.name//"unnamed"),$file,(.name//""),(.type//"")] | @tsv
  ' "$file" >> "$LOGIC"

done < <(find "$WORKFLOWS_DIR" -maxdepth 1 -type f -name '*.json' | sort)

while IFS= read -r file; do
  out="$GENERATED_DIR/workflows/$(basename "$file" .json).webhooks.json"
  jq '
    (if type=="array" then .[] else . end) as $w |
    {workflow_id:($w.id//""),workflow_name:($w.name//"unnamed"),active:($w.active//false),webhook_nodes:[($w.nodes//[])[]?|select(((.type//"")|ascii_downcase|contains("webhook")))]}
  ' "$file" > "$out"
done < <(find "$WORKFLOWS_DIR" -maxdepth 1 -type f -name '*.json' | sort)

REPORT="$GENERATED_DIR/reports/BOOKING_ENGINE_V2_BASELINE.md"
cat > "$REPORT" <<REPORT
# Baseline Booking Engine V2

- Générée le : $(date --iso-8601=seconds)
- Export source : \`$EXPORT_DIR\`

## Tables V2

\`\`\`text
$(cat "$GAP")
\`\`\`

## Workflows

\`\`\`text
$(cat "$WF")
\`\`\`

## Webhooks

\`\`\`text
$(cat "$WH")
\`\`\`

## Nœuds PostgreSQL

\`\`\`text
$(cat "$PG")
\`\`\`
REPORT

cp -a "$REPORT" "$FACTORY_DIR/docs/BOOKING_ENGINE_V2_BASELINE.md"
ln -sfn "$GENERATED_DIR" "$GENERATED_ROOT/latest"

ok "Analyse terminée"
echo
echo "Dossier généré : $GENERATED_DIR"
echo
echo "Rapports :"
echo "  $GAP"
echo "  $WF"
echo "  $WH"
echo "  $PG"
echo "  $LOGIC"
echo
echo "Aperçu tables :"
cat "$GAP"
echo
echo "Aperçu webhooks :"
cat "$WH"

