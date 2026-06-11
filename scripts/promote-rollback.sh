#!/bin/bash
# =====================================================
# Exécuté SUR le serveur PROD par rollback-prod.yml.
# Restaure une release backup créée par promote-prod-backup.sh.
#
# Structure attendue (cf. promote-prod-backup.sh) :
#   <site>/releases/<RELEASE_NAME>/db.sql.gz    ← DB prod
#   <site>/releases/<RELEASE_NAME>/code.tar.gz  ← httpdocs SAUF uploads
#   PROD_PATH = .../tech-o.pro/httpdocs  →  releases dans .../tech-o.pro/releases/
#
# Le tar code.tar.gz n'inclut PAS wp-content/uploads → les uploads actuels
# prod sont préservés (médias récents non écrasés).
# =====================================================
# Args:
#   $1 = PROD_PATH      (httpdocs prod ; layout bedrock = racine projet Bedrock)
#   $2 = RELEASE_NAME   (ex: tech-o.pro_2026-05-28_103256)
#   $3 = ACTION         (db | code)
#   $4 = LAYOUT         (classic | bedrock — optionnel, défaut classic)
#
# NOTE layout : la restauration est layout-agnostique.
#   - code : `tar xzf` écrase ce que l'archive contient (les excludes — uploads —
#     ont été appliqués à la CRÉATION par promote-prod-backup.sh selon le layout).
#   - db : `cd $PROD_PATH && wp db import` marche en classic ET en bedrock
#     (wp-cli.yml à la racine Bedrock pointe path: web/wp). PAS de --path= ici.
set -euo pipefail

PROD_PATH="${1:?PROD_PATH requis}"
RELEASE_NAME="${2:?RELEASE_NAME requis}"
ACTION="${3:?ACTION requis (db | code)}"
LAYOUT="${4:-classic}"
echo "▶ Rollback (action=${ACTION}, layout=${LAYOUT})"

SITE_DIR="$(dirname "$PROD_PATH")"          # ex: .../tech-o.pro
RELEASES_DIR="${SITE_DIR}/releases"
REL="${RELEASES_DIR}/${RELEASE_NAME}"

# === Garde-fous communs ===
if [ ! -d "$REL" ]; then
  echo "::error::Release introuvable : ${REL}"
  echo "Releases disponibles :"
  ls -1dt "${RELEASES_DIR}/"*/ 2>/dev/null || echo "  (aucune)"
  exit 1
fi

case "$ACTION" in
  code)
    SRC="${REL}/code.tar.gz"
    if [ ! -f "$SRC" ]; then
      echo "::error::Archive code introuvable : ${SRC}"; exit 1
    fi
    echo "▶ Restauration code (httpdocs SANS uploads) depuis ${SRC}"
    cd "$PROD_PATH"
    # Extraction overwrite : tar écrase les fichiers existants par défaut.
    # uploads non touchés (exclus à la création du backup).
    tar xzf "$SRC" -C "$PROD_PATH"
    echo "✓ Code restauré dans ${PROD_PATH} (uploads préservés)"
    ;;

  db)
    SRC="${REL}/db.sql.gz"
    if [ ! -f "$SRC" ]; then
      echo "::error::Dump DB introuvable : ${SRC}"; exit 1
    fi
    echo "▶ Restauration DB depuis ${SRC}"
    cd "$PROD_PATH"
    gunzip -c "$SRC" | wp db import -
    echo "✓ DB restaurée depuis la release ${RELEASE_NAME}"
    ;;

  *)
    echo "::error::ACTION invalide : '${ACTION}' (attendu: db | code)"
    exit 1
    ;;
esac
