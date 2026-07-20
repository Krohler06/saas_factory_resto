#!/usr/bin/env bash
set -Eeuo pipefail

BASE="${1:-/root/saas_factory}"
cd "$BASE"

echo "============================================================"
echo "Scan anti-secrets"
echo "Dossier : $BASE"
echo "============================================================"

BAD=0

echo
echo "[1/3] Recherche de fichiers sensibles"

SENSITIVE_FILES="$(
  find . \
    -path './exports' -prune -o \
    -path './.git' -prune -o \
    -type f \
    \( \
      -name '.env' -o \
      -name '*.env' -o \
      -name '*DO_NOT_COMMIT*' -o \
      -name '*decrypted*' -o \
      -name 'credentials.encrypted.json' -o \
      -name 'credentials.decrypted.json' -o \
      -name '*.key' -o \
      -name '*.pem' \
    \) \
    ! -name '.env.template' \
    ! -name 'example.env' \
    -print
)"

if [ -n "$SENSITIVE_FILES" ]; then
  echo "ERREUR: fichiers sensibles détectés :"
  echo "$SENSITIVE_FILES"
  BAD=1
else
  echo "OK: aucun fichier sensible évident détecté."
fi

echo
echo "[2/3] Recherche de secrets écrits en dur"

SECRET_MATCHES="$(
  find . \
    -path './exports' -prune -o \
    -path './.git' -prune -o \
    -path './data' -prune -o \
    -path './logs' -prune -o \
    -type f \
    ! -name '*.md' \
    ! -name '*.tgz' \
    ! -name '*.tar.gz' \
    ! -name '*.zip' \
    ! -name 'scan-secrets.sh' \
    -print0 \
  | xargs -0 awk '
    BEGIN {
      IGNORECASE=1
    }

    {
      line=$0
      file=FILENAME

      # Clés privées
      if (line ~ /BEGIN (RSA |OPENSSH |)PRIVATE KEY/) {
        print file ":" FNR ":" line
        next
      }

      # Lignes de type KEY=value
      if (line ~ /^[[:space:]]*[A-Z0-9_]*(PASSWORD|TOKEN|SECRET|API_KEY|PRIVATE_KEY|ENCRYPTION_KEY|JWT_SECRET)[A-Z0-9_]*[[:space:]]*=/) {
        split(line, parts, "=")
        value=line
        sub(/^[^=]*=/, "", value)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)

        # Valeurs vides ou placeholders
        if (value == "" || value ~ /^__.*__$/ || value ~ /__REPLACE_ME__/) next

        # Références de variables, pas un secret hardcodé
        if (value ~ /^\$/) next
        if (value ~ /\$\{[A-Z0-9_]+\}/) next
        if (value ~ /\$[A-Z0-9_]+/) next

        # Command substitution de génération, pas un secret hardcodé
        if (value ~ /\$\(/) next

        # Variables Docker/Compose référencées dans YAML
        if (value ~ /^\$\{.*\}$/) next

        # Exemple ou template
        if (file ~ /\.template$/ || file ~ /example/) next

        print file ":" FNR ":" line
      }
    }
  ' 2>/dev/null || true
)"

if [ -n "$SECRET_MATCHES" ]; then
  echo "ERREUR: secrets potentiels écrits en dur détectés :"
  echo "$SECRET_MATCHES"
  BAD=1
else
  echo "OK: aucun secret écrit en dur évident détecté."
fi

echo
echo "[3/3] Vérification Git staging"

if [ -d ".git" ]; then
  STAGED_SENSITIVE="$(
    git diff --cached --name-only 2>/dev/null \
      | grep -E '(^|/)(\.env|.*\.env|.*DO_NOT_COMMIT.*|.*decrypted.*|credentials\.encrypted\.json|credentials\.decrypted\.json|.*\.key|.*\.pem)$' \
      | grep -v '\.env\.template$' \
      | grep -v 'example\.env$' \
      || true
  )"

  if [ -n "$STAGED_SENSITIVE" ]; then
    echo "ERREUR: fichiers sensibles présents dans le staging Git :"
    echo "$STAGED_SENSITIVE"
    BAD=1
  else
    echo "OK: aucun fichier sensible dans le staging Git."
  fi
else
  echo "INFO: dépôt Git non initialisé, étape staging ignorée."
fi

echo
echo "============================================================"

if [ "$BAD" -ne 0 ]; then
  echo "Scan échoué : corrige avant commit/push."
  echo "============================================================"
  exit 1
fi

echo "OK: aucun secret évident détecté."
echo "============================================================"
