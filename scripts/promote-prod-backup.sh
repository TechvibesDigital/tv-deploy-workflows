#!/bin/bash
# =====================================================
# Exécuté SUR le serveur PROD par deploy-staging-to-prod.yml.
# Backup "release" de l'existant AVANT toute promotion → rollback rapide.
#
# Structure (isolée par site, hors docroot, sur Plesk mutualisé) :
#   <site>/releases/<site>_<TS>/db.sql.gz    ← DB prod
#   <site>/releases/<site>_<TS>/code.tar.gz  ← httpdocs SAUF uploads
#   PROD_PATH = .../tech-o.pro/httpdocs  →  releases dans .../tech-o.pro/releases/
#
# Uploads exclus volontairement (gros, peu compressibles, déjà sur staging).
# Rotation : on ne garde que les 3 dernières releases du site.
# =====================================================
# Args:
#   $1 = PROD_PATH   (httpdocs prod ; layout bedrock = racine projet Bedrock)
#   $2 = TS          (timestamp, ex: 2026-05-28_143000)
#   $3 = LAYOUT      (classic | bedrock — optionnel, défaut classic)
set -euo pipefail

PROD_PATH="${1:?PROD_PATH requis}"
TS="${2:?TS requis}"
LAYOUT="${3:-classic}"

KEEP=3                                 # nombre de releases conservées
SITE_DIR="$(dirname "$PROD_PATH")"     # ex: .../tech-o.pro
SITE_NAME="$(basename "$SITE_DIR")"    # ex: tech-o.pro
RELEASES_DIR="${SITE_DIR}/releases"
REL="${RELEASES_DIR}/${SITE_NAME}_${TS}"
mkdir -p "$REL"
cd "$PROD_PATH"

echo "▶ Backup DB prod → ${REL}/db.sql.gz"
wp db export "${REL}/db.sql" --quiet
gzip -f "${REL}/db.sql"

echo "▶ Backup code (layout=${LAYOUT}, SANS uploads) → ${REL}/code.tar.gz"
# Excludes selon layout : classic = wp-content/*, bedrock = web/app/*.
if [ "$LAYOUT" = "bedrock" ]; then
  TAR_EXCLUDES=(
    --exclude='web/app/uploads'
    --exclude='web/app/cache'
    --exclude='web/app/upgrade'
    --exclude='web/app/wflogs'
  )
else
  TAR_EXCLUDES=(
    --exclude='wp-content/uploads'
    --exclude='wp-content/cache'
    --exclude='wp-content/wflogs'
    --exclude='wp-content/ai1wm-backups'
  )
fi
# Le site prod est vivant : des fichiers (cache/sessions) peuvent changer pendant
# la lecture → tar sort code 1 (avertissement, archive valide). On tolère ≤1,
# on n'échoue que sur une vraie erreur (≥2).
set +e
tar czf "${REL}/code.tar.gz" -C "$PROD_PATH" \
  --warning=no-file-changed \
  "${TAR_EXCLUDES[@]}" \
  .
TAR_RC=$?
set -e
if [ "$TAR_RC" -gt 1 ]; then
  echo "::error::tar a échoué (code ${TAR_RC})"; exit "$TAR_RC"
fi

echo "▶ Rotation : on garde les ${KEEP} dernières releases de ${SITE_NAME}"
ls -1dt "${RELEASES_DIR}/${SITE_NAME}_"*/ 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -rf

echo "✓ Backup release OK : ${REL}/ (rollback : import db.sql.gz + extraction code.tar.gz)"
