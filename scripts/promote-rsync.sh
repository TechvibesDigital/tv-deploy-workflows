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
#   $2 = PROD_PATH     (httpdocs prod, destination ; layout bedrock = racine projet Bedrock)
#   $3 = PROD_PORT     (défaut 22)
#   $4 = SYNC_UPLOADS  (true/false)
#   $5 = STAGING_PATH  (httpdocs staging, source ; layout bedrock = racine projet Bedrock)
#   $6 = DRY_RUN       (true/false ; true = simulation, rien n'est écrit)
#   $7 = LAYOUT        (classic | bedrock — optionnel, défaut classic)
set -euo pipefail

PROD_TARGET="${1:?PROD_TARGET requis}"
PROD_PATH="${2:?PROD_PATH requis}"
PROD_PORT="${3:-22}"
SYNC_UPLOADS="${4:-true}"
STAGING_PATH="${5:?STAGING_PATH requis}"
DRY_RUN="${6:-false}"
LAYOUT="${7:-classic}"

if [ "$LAYOUT" = "bedrock" ]; then
  # === Layout BEDROCK ===
  # On ne pousse QUE les éléments du release Bedrock : web/ config/ vendor/
  # composer.json composer.lock wp-cli.yml. Le .env prod n'est JAMAIS écrasé
  # (exclude + protect), idem .htaccess du docroot (web/.htaccess, propre au serveur).
  SOURCES=()
  for item in web config vendor composer.json composer.lock wp-cli.yml; do
    if [ -e "${STAGING_PATH}/${item}" ]; then
      SOURCES+=( "${STAGING_PATH}/${item}" )
    else
      echo "⚠ ${STAGING_PATH}/${item} absent côté staging — ignoré"
    fi
  done
  if [ ! -d "${STAGING_PATH}/web" ]; then
    echo "::error::layout=bedrock mais ${STAGING_PATH}/web introuvable — STAGING_PATH doit pointer la racine du projet Bedrock"
    exit 1
  fi
  EXCLUDES=(
    --exclude='.env'
    --exclude='.env.*'
    --exclude='.ddev/'
    --exclude='.user.ini'
    --exclude='web/.htaccess'
    --exclude='web/.user.ini'
    --exclude='.git/'
    --exclude='.github/'
    --exclude='web/app/cache/'
    --exclude='web/app/upgrade/'
    --exclude='web/app/upgrade-temp-backup/'
    --exclude='web/app/wflogs/'
    --exclude='web/app/uploads/cache/'
    --exclude='*.log'
    --exclude='error_log'
  )
  if [ "$SYNC_UPLOADS" != "true" ]; then
    EXCLUDES+=( --exclude='web/app/uploads/' )
  fi
  # Protège du --delete : .env prod + plugins/langues éventuellement présents
  # uniquement côté prod (mis à jour si présents en staging, jamais supprimés).
  PROTECT=(
    --filter='protect .env'
    --filter='protect web/.htaccess'
    --filter='protect web/app/plugins/***'
    --filter='protect web/app/languages/***'
  )
else
  # === Layout CLASSIC (comportement historique, inchangé) ===
  SOURCES=( "${STAGING_PATH}/" )
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
fi

RSYNC_OPTS=( -avz --delete )
if [ "$DRY_RUN" = "true" ]; then
  RSYNC_OPTS+=( -n --stats )
  echo "▶ MODE DRY-RUN — simulation, AUCUNE écriture sur prod"
fi

echo "▶ Rsync staging → ${PROD_TARGET}:${PROD_PATH} (layout=${LAYOUT}, uploads=${SYNC_UPLOADS}, dry_run=${DRY_RUN})"
rsync "${RSYNC_OPTS[@]}" "${PROTECT[@]}" "${EXCLUDES[@]}" \
  -e "ssh -p ${PROD_PORT} -o StrictHostKeyChecking=accept-new" \
  "${SOURCES[@]}" \
  "${PROD_TARGET}:${PROD_PATH}/"

if [ "$DRY_RUN" = "true" ]; then
  echo "✓ DRY-RUN terminé (ci-dessus = ce qui SERAIT poussé/supprimé)"
else
  echo "✓ Code synchronisé staging → prod"
fi
