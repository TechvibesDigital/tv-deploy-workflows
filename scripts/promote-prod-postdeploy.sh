#!/bin/bash
# =====================================================
# Exécuté SUR le serveur PROD par deploy-staging-to-prod.yml,
# APRÈS le push code + import DB.
#
# search-replace OBLIGATOIRE staging → prod, retrait des outils de fabrication
# (journal d'activité), puis flush caches, permaliens, perms, et .htaccess WP
# si absent.
# =====================================================
# Args:
#   $1 = PROD_PATH    (httpdocs prod ; layout bedrock = racine projet Bedrock)
#   $2 = STAGING_URL  (ex: https://tech-o.tv-staging.ma)
#   $3 = PROD_URL     (ex: https://tech-o.fr)
#   $4 = LAYOUT       (classic | bedrock — optionnel, défaut classic)
#
# NOTE layout : toutes les commandes wp passent par `cd $PROD_PATH && wp`
# (compatible bedrock via wp-cli.yml). Seuls le dossier contenu (wp-content
# vs web/app) et l'emplacement du .htaccess (racine vs web/) diffèrent.
set -euo pipefail

PROD_PATH="${1:?PROD_PATH requis}"
STAGING_URL="${2:?STAGING_URL requis}"
PROD_URL="${3:?PROD_URL requis}"
LAYOUT="${4:-classic}"

if [ "$LAYOUT" = "bedrock" ]; then
  CONTENT_DIR="web/app"   # équivalent wp-content en Bedrock
  DOCROOT="web"           # docroot servi (le .htaccess vit là)
else
  CONTENT_DIR="wp-content"
  DOCROOT="."
fi

cd "$PROD_PATH"
echo "▶ Post-deploy prod (layout=${LAYOUT})"

STAGING_HOST="${STAGING_URL#*://}"
PROD_HOST="${PROD_URL#*://}"

echo "▶ search-replace ${STAGING_URL} → ${PROD_URL}"
wp search-replace "$STAGING_URL" "$PROD_URL" --all-tables --skip-columns=guid
# http:// au cas où + hostname seul (URLs protocol-relative)
wp search-replace "http://${STAGING_HOST}" "$PROD_URL" --all-tables --skip-columns=guid || true
wp search-replace "$STAGING_HOST" "$PROD_HOST" --all-tables --skip-columns=guid || true

# Elementor : URLs sérialisées internes + régénération CSS
if wp plugin is-installed elementor 2>/dev/null; then
  echo "▶ Elementor replace_urls + flush_css"
  wp elementor replace_urls "$STAGING_URL" "$PROD_URL" 2>/dev/null || true
  wp elementor replace_urls "http://${STAGING_HOST}" "$PROD_URL" 2>/dev/null || true
  wp elementor flush_css 2>/dev/null || true
fi

echo "▶ home / siteurl → ${PROD_URL}"
wp option update home "$PROD_URL"
wp option update siteurl "$PROD_URL"
# elementor_log peut garder des URLs dans des stack traces
wp option update elementor_log "" 2>/dev/null || true

# Lever la restriction d'indexation héritée du staging (CLAUDE.md §5.3).
# Le staging est toujours noindex (blog_public=0) ; sans ça la prod reste
# invisible de Google après chaque mise en prod (vécu : elka, sct-tolerie).
echo "▶ blog_public → 1 (prod indexable)"
wp option update blog_public 1

# Outils de FABRICATION : utiles pendant l'intégration (suivi du travail des
# intégrateurs), sans objet sur le site livré. Le rsync les apporte depuis le
# staging et l'import de DB apporte leurs tables : on les retire ici, à chaque
# promotion. La désinstallation WordPress joue leur uninstall.php, qui supprime
# tables et options ; on nettoie ensuite les résidus éventuels.
BUILD_ONLY_PLUGINS="simple-history"
for plug in $BUILD_ONLY_PLUGINS; do
  if wp plugin is-installed "$plug" 2>/dev/null; then
    echo "▶ Outil de fabrication retiré de la prod : ${plug}"
    # `plugin uninstall`, pas `plugin delete` : delete supprime les FICHIERS
    # sans jouer uninstall.php (dixit sa doc), ce qui laisserait les tables du
    # journal et ses options dans la base du client. uninstall désinstalle
    # proprement ET supprime les fichiers.
    wp plugin uninstall "$plug" --deactivate --quiet 2>/dev/null || true
  fi
done

# Résidus : si l'uninstall n'a pas tourné (plugin absent du disque mais tables
# importées avec la DB), on supprime tables et options à la main.
DB_PREFIX="$(wp db prefix 2>/dev/null | tr -d '[:space:]' || true)"
if [ -n "$DB_PREFIX" ]; then
  for leftover in simple_history simple_history_contexts; do
    wp db query "DROP TABLE IF EXISTS ${DB_PREFIX}${leftover}" 2>/dev/null || true
  done
fi
# Pas de pipeline vers while : sous pipefail un wp en échec ferait tomber la
# promotion entière pour un simple nettoyage d'options.
LEFTOVER_OPTIONS="$(wp option list --search='simple_history*' --field=option_name 2>/dev/null || true)"
for opt in $LEFTOVER_OPTIONS; do
  wp option delete "$opt" 2>/dev/null || true
done

echo "▶ Flush caches (on NE force PAS la structure de permaliens — on garde celle de la prod)"
wp rewrite flush --hard 2>/dev/null || true
wp cache flush 2>/dev/null || true
wp transient delete --all 2>/dev/null || true

if [ ! -s "${DOCROOT}/.htaccess" ]; then
  echo "▶ ${DOCROOT}/.htaccess absent → création (WP par défaut)"
  cat > "${DOCROOT}/.htaccess" <<'HT'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
HT
fi

echo "▶ Permissions ${CONTENT_DIR} (644 fichiers / 755 dossiers)"
find "$CONTENT_DIR" -type f -exec chmod 644 {} \; 2>/dev/null || true
find "$CONTENT_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true

echo "✓ Post-deploy prod terminé — ${PROD_URL}"
