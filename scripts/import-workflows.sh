#!/usr/bin/env bash
set -Eeuo pipefail

CLIENT_DIR="${1:?Usage: import-workflows.sh /opt/clients/<client_id>}"

cd "$CLIENT_DIR"
set -a
source .env
set +a

N8N_CONTAINER="${CLIENT_ID}_n8n"

if ! docker ps --format '{{.Names}}' | grep -qx "$N8N_CONTAINER"; then
echo "ERREUR: conteneur n8n non démarré: $N8N_CONTAINER" >&2
exit 1
fi

if [ -f "$CLIENT_DIR/workflows/workflows.all.json" ]; then
echo "Import workflows depuis workflows.all.json"
docker exec -u node "$N8N_CONTAINER" n8n import:workflow
--input=/workflows/workflows.all.json
elif [ -d "$CLIENT_DIR/workflows/separate" ]; then
echo "Import workflows depuis workflows/separate"
for wf in "$CLIENT_DIR"/workflows/separate/*.json; do
[ -f "$wf" ] || continue
base="$(basename "$wf")"
echo " - $base"
docker exec -u node "$N8N_CONTAINER" n8n import:workflow
--input="/workflows/separate/$base"
done
else
echo "Aucun workflow à importer dans $CLIENT_DIR/workflows" >&2
exit 1
fi

echo "Import terminé."
echo "Attention: vérifier les credentials dans l’interface n8n avant activation production."
