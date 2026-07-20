#!/usr/bin/env bash

set -Eeuo pipefail

CADDY_CONTAINER="${1:-edge-caddy}"

echo "============================================================"
echo "CONTENEUR CADDY"
echo "============================================================"

if ! docker inspect "$CADDY_CONTAINER" >/dev/null 2>&1; then
  echo "Conteneur introuvable : $CADDY_CONTAINER"
  exit 1
fi

docker inspect \
  --format 'Nom={{.Name}} Image={{.Config.Image}} Etat={{.State.Status}}' \
  "$CADDY_CONTAINER"

echo
echo "============================================================"
echo "RESEAUX DU CONTENEUR CADDY"
echo "============================================================"

docker inspect \
  --format '{{range $name, $network := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
  "$CADDY_CONTAINER"

echo
echo "============================================================"
echo "MONTAGES DU CONTENEUR CADDY"
echo "============================================================"

docker inspect \
  --format '{{range .Mounts}}{{println .Source " -> " .Destination}}{{end}}' \
  "$CADDY_CONTAINER"

echo
echo "============================================================"
echo "RESEAUX DOCKER DISPONIBLES"
echo "============================================================"

docker network ls \
  --format 'table {{.Name}}\t{{.Driver}}\t{{.Scope}}'

echo
echo "============================================================"
echo "VALIDATION CADDY"
echo "============================================================"

docker exec "$CADDY_CONTAINER" \
  caddy validate \
  --config /etc/caddy/Caddyfile \
  || true

echo
echo "Renseigne ensuite config/factory.yml avec :"
echo "- le réseau partagé avec Caddy ;"
echo "- le répertoire hôte des routes ;"
echo "- le chemin du Caddyfile dans le conteneur."

