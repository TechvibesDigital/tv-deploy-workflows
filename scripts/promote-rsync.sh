#!/bin/bash
# =====================================================
# Exécuté SUR le serveur STAGING par deploy-staging-to-prod.yml
# (lancé via `ssh -A` : l'agent SSH du runner est forwardé, donc
# la clé prod est dispo ici pour le rsync staging → prod).
#
# Rsync DIRECT staging → prod, code complet + uploads.
# On EXCLUT tout ce qui est local/dev ou propre au serveur :
# le client reste maître de wp-config, .htaccess, .user.ini.
# =====================================================
# Args:
#   $1 = PROD_TARGET   (user@host)
#   $2 = PROD_PATH     (httpdocs prod, destination)
#   $3 = PROD_PORT     (défaut 22)
#   $4 = SYNC_UPLOADS  (true/false)
#   $5 = STAGING_PATH  (httpdocs staging, source)
#   $6 = DRY_RUN       (true/false ; true = simulation, rien n'est écrit)
set -euo pipefail

PROD_TARGET="${1:?PROD_TARGET requis}"
PROD_PATH="${2:?PROD_PATH requis}"
PROD_PORT="${3:-22}"
SYNC_UPLOADS="${4:-true}"
STAGING_PATH="${5:?STAGING_PATH requis}"
DRY_RUN="${6:-false}"

EXCLUDES=(
  --exclude='wp-config.php'
  --exclude='wp-config-ddev.php'
  --exclude='.env'
  --exclude='.env.*'
  --exclude='.ddev/'
  --exclude='.user.ini'
  --exclude='.htaccess'
  --exclude='.git/'
  --exclude='.github/'
  --exclude='wp-content/cache/'
  --exclude='wp-content/upgrade/'
  --exclude='wp-content/upgrade-temp-backup/'
  --exclude='wp-content/wflogs/'
  --exclude='wp-content/uploads/cache/'
  --exclude='*.log'
  --exclude='error_log'
)

if [ "$SYNC_UPLOADS" != "true" ]; then
  EXCLUDES+=( --exclude='wp-content/uploads/' )
fi

# Protège du --delete ce que la prod peut avoir en plus de staging :
# plugins tiers/sécurité installés côté client + langues. Ils restent mis à
# jour si présents en staging, mais ne sont JAMAIS supprimés s'ils manquent.
PROTECT=(
  --filter='protect wp-content/plugins/***'
  --filter='protect wp-content/languages/***'
)

RSYNC_OPTS=( -avz --delete )
if [ "$DRY_RUN" = "true" ]; then
  RSYNC_OPTS+=( -n --stats )
  echo "▶ MODE DRY-RUN — simulation, AUCUNE écriture sur prod"
fi

echo "▶ Rsync staging → ${PROD_TARGET}:${PROD_PATH} (uploads=${SYNC_UPLOADS}, dry_run=${DRY_RUN})"
rsync "${RSYNC_OPTS[@]}" "${PROTECT[@]}" "${EXCLUDES[@]}" \
  -e "ssh -p ${PROD_PORT} -o StrictHostKeyChecking=accept-new" \
  "${STAGING_PATH}/" \
  "${PROD_TARGET}:${PROD_PATH}/"

if [ "$DRY_RUN" = "true" ]; then
  echo "✓ DRY-RUN terminé (ci-dessus = ce qui SERAIT poussé/supprimé)"
else
  echo "✓ Code synchronisé staging → prod"
fi
