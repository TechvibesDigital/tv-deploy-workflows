#!/bin/bash
# =====================================================
# Exécuté SUR le serveur STAGING par deploy-staging-to-prod.yml
# (lancé via `ssh -A` : agent forwardé → clé prod dispo).
#
# Pipe la DB staging → prod sans fichier intermédiaire.
# Le backup de la DB prod a déjà été fait (promote-prod-backup.sh).
# Le search-replace est fait APRÈS, côté prod (promote-prod-postdeploy.sh).
# =====================================================
# Args:
#   $1 = PROD_TARGET   (user@host)
#   $2 = PROD_PATH     (httpdocs prod)
#   $3 = PROD_PORT     (défaut 22)
#   $4 = STAGING_PATH  (httpdocs staging)
set -euo pipefail

PROD_TARGET="${1:?PROD_TARGET requis}"
PROD_PATH="${2:?PROD_PATH requis}"
PROD_PORT="${3:-22}"
STAGING_PATH="${4:?STAGING_PATH requis}"

cd "$STAGING_PATH"

echo "▶ Export DB staging → import prod (pipe gzip, charset utf8mb4)..."
# --default-character-set=utf8mb4 : évite le mojibake si collation cible legacy.
# sed : le staging tourne sur MariaDB récente (collations *_uca1400_*) que la
#       prod (Plesk, MySQL/MariaDB plus ancienne) ne connaît pas → on les
#       ramène vers *_general_ci (même logique que tv-staging-pull pour le local).
# bash -lc côté prod : Plesk SSH non-interactif n'a pas php/wp dans le PATH.
wp db export - --quiet --default-character-set=utf8mb4 \
  | sed -E 's/utf8mb4_uca1400_ai_ci/utf8mb4_general_ci/g; s/utf8mb3_uca1400_ai_ci/utf8mb3_general_ci/g; s/utf8_uca1400_ai_ci/utf8_general_ci/g; s/_uca1400_[a-z]+_c[is]/_general_ci/g' \
  | gzip \
  | ssh -p "${PROD_PORT}" -o StrictHostKeyChecking=accept-new "${PROD_TARGET}" \
      "bash -lc 'gunzip | wp --path=\"\$0\" db import - --default-character-set=utf8mb4' '${PROD_PATH}'"

echo "✓ DB staging importée sur prod (search-replace à suivre)"
