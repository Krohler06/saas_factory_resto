#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/root/saas_factory"

bash "$BASE/scripts/promote-latest-export.sh"
bash "$BASE/scripts/scan-secrets.sh"

echo
echo "Bootstrap terminé."
echo
echo "Vérification :"
echo " tree -a $BASE/template"
echo
echo "Git :"
echo " cd $BASE"
echo " bash scripts/git-init-safe.sh"
