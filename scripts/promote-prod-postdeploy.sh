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
TS="${5:-}"                      # timestamp de la release (pour retrouver le snapshot users prod)
FIRST_GOLIVE="${6:-false}"       # true = tout 1er go-live du projet (sème podium+client du staging)

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

# === Réconciliation des comptes : la prod reste à eux, un seul accès interne techvibes ===
# L'import DB staging a écrasé wp_users prod. On rend la table à son propriétaire
# (snapshot pré-import pris par promote-prod-backup.sh) et on n'ajoute QUE techvibes,
# notre accès de maintenance. Chaque contenu est reconnecté à son auteur réel PAR
# EMAIL : le nôtre (@techvibes.ma) sous techvibes, le leur (podium "dev_xxxx", client)
# sous leur propre compte prod. On ne s'attribue pas leur travail. Clé = email,
# jamais le login. La base prod ayant été réalignée sur le prefix du staging
# (promote-prod-prepare.sh), on réécrit le prefix du snapshot avant réimport.
if [ -n "$TS" ]; then
  SITE_DIR="$(dirname "$PROD_PATH")"; SITE_NAME="$(basename "$SITE_DIR")"
  REL_DIR="${SITE_DIR}/releases/${SITE_NAME}_${TS}"
  PROD_USERS_DUMP="${REL_DIR}/prod-users.sql"
  PFX=$(wp db prefix 2>/dev/null | tr -d '[:space:]'); PFX="${PFX:-wp_}"

  # 1. Carte des auteurs du contenu importé, AVANT de restaurer la table prod (ID staging -> email).
  AUTHOR_MAP=$(wp db query "SELECT DISTINCT u.ID, u.user_email FROM ${PFX}users u JOIN ${PFX}posts p ON p.post_author=u.ID;" --skip-column-names 2>/dev/null || true)
  # Hash techvibes tel qu'il arrive du staging (= registre TV_WP_TEAM) : aucun secret stocké ici.
  TV_HASH=$(wp db query "SELECT user_pass FROM ${PFX}users WHERE user_login='techvibes' LIMIT 1;" --skip-column-names 2>/dev/null | tr -d '[:space:]' || true)
  TV_EMAIL=$(wp db query "SELECT user_email FROM ${PFX}users WHERE user_login='techvibes' LIMIT 1;" --skip-column-names 2>/dev/null | tr -d '[:space:]' || true)
  [ -n "$TV_EMAIL" ] || TV_EMAIL="technique@techvibes.ma"

  # 2. Table users : restaurer celle de la prod (go-live suivant) ou garder le staging (1er go-live).
  if [ "${FIRST_GOLIVE}" = "true" ]; then
    echo "▶ Premier go-live : on garde les comptes du staging (semis podium + client)"
  elif [ -s "$PROD_USERS_DUMP" ]; then
    echo "▶ Restauration des users prod (leurs comptes, leurs mots de passe)"
    PFX_ORIG="$(cat "${REL_DIR}/prod-users.prefix" 2>/dev/null | tr -d '[:space:]')"; PFX_ORIG="${PFX_ORIG:-$PFX}"
    if [ "$PFX_ORIG" != "$PFX" ]; then
      # Réécriture des noms de tables (prefix d'origine -> prefix courant), dans
      # les backticks mysqldump (CREATE/DROP/INSERT/LOCK), avant réimport.
      sed -E "s/\`${PFX_ORIG}(users|usermeta)\`/\`${PFX}\1\`/g" "$PROD_USERS_DUMP" | wp db import - \
        || echo "::warning::restauration des users prod échouée (prefix réécrit), comptes laissés tels quels"
    else
      wp db import "$PROD_USERS_DUMP" \
        || echo "::warning::restauration des users prod échouée, comptes laissés tels quels"
    fi
  else
    echo "::warning::snapshot users prod introuvable (${PROD_USERS_DUMP}), traité comme 1er go-live (semis staging)"
  fi

  # 3. Garantir techvibes (accès interne unique), mot de passe = registre (hash capturé du staging).
  wp user get techvibes --field=ID >/dev/null 2>&1 \
    || wp user create techvibes "$TV_EMAIL" --role=administrator --user_pass="tmp-$(date +%s)" >/dev/null
  TV_ID=$(wp user get techvibes --field=ID 2>/dev/null)
  if [ -n "$TV_ID" ]; then
    wp user add-role "$TV_ID" administrator >/dev/null 2>&1 || true
    [ -n "$TV_HASH" ] && wp db query "UPDATE ${PFX}users SET user_pass='${TV_HASH}' WHERE ID=${TV_ID};" 2>/dev/null || true

    # 4. Reconnecter chaque contenu à son auteur réel (le nôtre -> techvibes, le leur -> leur compte).
    AUTHOR_CASE=""
    while IFS=$'\t' read -r SID EMAIL; do
      [ -n "$SID" ] || continue
      case "$EMAIL" in
        *@techvibes.ma) TID="$TV_ID" ;;
        *) TID=$(wp db query "SELECT ID FROM ${PFX}users WHERE user_email='${EMAIL}' LIMIT 1;" --skip-column-names 2>/dev/null | tr -d '[:space:]')
           [ -n "$TID" ] || { TID="$TV_ID"; echo "::warning::auteur ${EMAIL} absent de la prod, contenu laissé à techvibes"; } ;;
      esac
      AUTHOR_CASE="${AUTHOR_CASE} WHEN ${SID} THEN ${TID}"
    done <<< "$AUTHOR_MAP"
    [ -n "$AUTHOR_CASE" ] \
      && wp db query "UPDATE ${PFX}posts SET post_author = CASE post_author ${AUTHOR_CASE} ELSE post_author END;" 2>/dev/null || true

    # 5. Retrait des internes @techvibes.ma sauf techvibes (contenu déjà remappé, donc pas d'orphelin).
    #    Nettoie aussi au passage une prod contaminée par l'ancien comportement.
    wp db query "DELETE m FROM ${PFX}usermeta m JOIN ${PFX}users u ON u.ID=m.user_id WHERE u.user_email LIKE '%@techvibes.ma' AND u.user_login<>'techvibes';" 2>/dev/null || true
    wp db query "DELETE FROM ${PFX}users WHERE user_email LIKE '%@techvibes.ma' AND user_login<>'techvibes';" 2>/dev/null || true
    echo "✓ Comptes réconciliés : users prod préservés, techvibes (#${TV_ID}) ajouté, internes retirés"
  else
    echo "::warning::techvibes introuvable après création, réconciliation des comptes sautée"
  fi
else
  echo "⚠ TS non fourni, réconciliation des comptes sautée (pipeline promote.yml pas à jour ?)"
fi

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
