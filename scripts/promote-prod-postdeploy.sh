#!/bin/bash
# =====================================================
# Exécuté SUR le serveur PROD par deploy-staging-to-prod.yml,
# APRÈS le push code + import DB.
#
# search-replace OBLIGATOIRE staging → prod, puis flush caches,
# permaliens, perms, et .htaccess WP si absent.
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
