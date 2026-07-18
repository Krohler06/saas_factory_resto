#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/root/saas_factory"
cd "$BASE"

bash "$BASE/scripts/scan-secrets.sh" "$BASE"

if [ ! -d .git ]; then
git init
fi

git add \
.gitignore \
README.md \
docs \
scripts \
template \

git status --short

echo
read -r -p "Créer le commit initial ? [y/N] " confirm

case "$confirm" in
y|Y|yes|YES)
git commit -m "chore: initialize saas factory template"
echo "Commit créé."
;;
*)
echo "Commit annulé. Les fichiers sont ajoutés au staging."
;;
esac
