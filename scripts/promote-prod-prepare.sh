#!/bin/bash
# =====================================================
# Exécuté SUR le serveur PROD par deploy-staging-to-prod.yml,
# AVANT le rsync et l'import de DB.
#
# Prépare la prod au lieu de simplement la vérifier :
#   1. aligne le table_prefix de la prod sur celui du staging ;
#   2. pose un fichier témoin, que le workflow ira chercher en HTTP pour
#      confirmer que le docroot servi est bien PROD_PATH.
#
# Pourquoi aligner plutôt que refuser : la promotion REMPLACE la base de la
# prod par celle du staging. Le prefix que la prod avait avant ne survit pas à
# l'import ; exiger qu'il soit déjà identique imposait une correction manuelle
# à chaque première mise en ligne (Plesk génère un prefix aléatoire à chaque
# installation : MM5HlsA_, jL2zq_, ZnsYgRE_, FDc9gRbXC_…).
# Le wp-config.php d'origine reste dans la release de sauvegarde, et une copie
# horodatée est posée à côté avant modification.
# =====================================================
# Args:
#   $1 = PROD_PATH     (httpdocs prod ; bedrock = racine du projet)
#   $2 = STG_PREFIX    (table_prefix du staging, fait foi)
#   $3 = TS            (horodatage, pour la copie de secours et le témoin)
#   $4 = LAYOUT        (classic | bedrock)
#   $5 = MARKER        (nom du fichier témoin à poser dans le docroot)
set -euo pipefail

PROD_PATH="${1:?PROD_PATH requis}"
STG_PREFIX="${2:?STG_PREFIX requis}"
TS="${3:?TS requis}"
LAYOUT="${4:-classic}"
MARKER="${5:-}"

cd "$PROD_PATH"

# ─── 1. table_prefix ────────────────────────────────────────────────────────
PFX_PROD="$(wp config get table_prefix 2>/dev/null || wp db prefix 2>/dev/null || true)"
PFX_PROD="$(printf '%s' "$PFX_PROD" | tr -d '[:space:]')"

if [ "$PFX_PROD" = "$STG_PREFIX" ]; then
  echo "✓ table_prefix déjà aligné : ${STG_PREFIX}"
elif [ "$LAYOUT" = "bedrock" ]; then
  # En bedrock le prefix vit dans config/application.php : pas de réécriture
  # automatique, le fichier n'a pas de forme garantie.
  echo "::error::table_prefix divergent (staging=${STG_PREFIX}, prod=${PFX_PROD}) et layout bedrock — aligne-le à la main dans config/application.php"
  exit 1
else
  echo "▶ table_prefix prod '${PFX_PROD}' → '${STG_PREFIX}' (la base prod est remplacée par celle du staging)"
  cp wp-config.php "wp-config.php.bak-${TS}"
  if ! wp config set table_prefix "$STG_PREFIX" --type=variable --quiet 2>/dev/null; then
    # wp-cli échoue sur un wp-config sans ancre : réécriture directe de la ligne.
    sed -i -E "s/^([[:space:]]*\\\$table_prefix[[:space:]]*=[[:space:]]*)['\"][^'\"]*['\"]/\\1'${STG_PREFIX}'/" wp-config.php
  fi
  php -l wp-config.php >/dev/null || { echo "::error::wp-config.php invalide après réécriture — restauré"; cp "wp-config.php.bak-${TS}" wp-config.php; exit 1; }
  NEW="$(wp config get table_prefix 2>/dev/null | tr -d '[:space:]' || true)"
  [ "$NEW" = "$STG_PREFIX" ] || { echo "::error::table_prefix toujours '${NEW}' après réécriture — restauré"; cp "wp-config.php.bak-${TS}" wp-config.php; exit 1; }
  echo "✓ table_prefix aligné sur ${STG_PREFIX} (sauvegarde : wp-config.php.bak-${TS})"
fi

# ─── 2. Témoin de docroot ───────────────────────────────────────────────────
# Le workflow le demandera en HTTP. S'il ne le trouve pas, c'est que le serveur
# sert un autre dossier que PROD_PATH (Document root Plesk réglé sur la racine
# du domaine au lieu de httpdocs) : le site déployé serait invisible.
if [ -n "$MARKER" ]; then
  DOCROOT="$PROD_PATH"
  [ "$LAYOUT" = "bedrock" ] && DOCROOT="${PROD_PATH}/web"
  printf 'tv-promote %s\n' "$TS" > "${DOCROOT}/${MARKER}"
  chmod 644 "${DOCROOT}/${MARKER}"
  echo "✓ témoin posé : ${DOCROOT}/${MARKER}"
fi
