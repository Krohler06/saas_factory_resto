#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/root/saas_factory"
LATEST="$(find "$BASE/exports" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' 2>/dev/null | sort -nr | awk 'NR==1{print $2}')"

if [ -z "${LATEST:-}" ]; then
echo "ERREUR: aucun export trouvé dans $BASE/exports" >&2
exit 1
fi

echo "Dernier export détecté : $LATEST"
bash "$BASE/scripts/promote-export-to-template.sh" "$LATEST"
