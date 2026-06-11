# tv-deploy-workflows

Workflows GitHub Actions **réutilisables** TechVibes pour le déploiement WordPress :
- `promote.yml` — promotion COMPLÈTE staging → prod (code + DB + uploads)
- `rollback.yml` — restauration d'une release backup en 1 clic

> **But** : un fix CI/CD = **1 PR central**, propagé à tous les projets clients via tag (`@v1`).
> Plus besoin de re-pusher dans chaque repo client.

## Architecture

```
                  ┌──────────────────────────────────────┐
                  │  TechvibesDigital/tv-deploy-workflows│
                  │                                      │
                  │  .github/workflows/promote.yml       │
                  │  .github/workflows/rollback.yml      │
                  │  scripts/promote-*.sh                │
                  │                                      │
                  │  tag v1, v2, …                       │
                  └─────────────┬────────────────────────┘
                                │ uses: …@v1
            ┌───────────────────┼───────────────────┐
            ▼                   ▼                   ▼
   ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
   │  client-X    │   │  client-Y    │   │  client-Z    │
   │   stub.yml   │   │   stub.yml   │   │   stub.yml   │
   └──────────────┘   └──────────────┘   └──────────────┘
```

Chaque projet client ne contient plus qu'un **stub** minimal (~20 lignes) qui appelle le workflow central.

## Usage minimal — Stub côté projet client

### `deploy-staging-to-prod.yml` (promotion)

```yaml
# .github/workflows/deploy-staging-to-prod.yml — dans le repo client
name: Promote Staging → Production (Full Release)

on:
  workflow_dispatch:
    inputs:
      confirm:
        description: "Tape DEPLOY pour confirmer"
        required: true
      sync_database:
        type: boolean
        default: true
      sync_uploads:
        type: boolean
        default: true
      dry_run:
        type: boolean
        default: false

jobs:
  promote:
    uses: TechvibesDigital/tv-deploy-workflows/.github/workflows/promote.yml@v1
    secrets: inherit
    with:
      confirm: ${{ inputs.confirm }}
      sync_database: ${{ inputs.sync_database }}
      sync_uploads: ${{ inputs.sync_uploads }}
      dry_run: ${{ inputs.dry_run }}
```

### `rollback-prod.yml` (rollback)

```yaml
# .github/workflows/rollback-prod.yml — dans le repo client
name: Rollback Production (Release Restore)

on:
  workflow_dispatch:
    inputs:
      confirm:
        description: "Tape ROLLBACK pour confirmer"
        required: true
      release_name:
        description: "Nom du dossier release (ex: tech-o.pro_2026-05-28_103256)"
        required: true
      restore_db:
        type: boolean
        default: true
      restore_code:
        type: boolean
        default: true

jobs:
  rollback:
    uses: TechvibesDigital/tv-deploy-workflows/.github/workflows/rollback.yml@v1
    secrets: inherit
    with:
      confirm: ${{ inputs.confirm }}
      release_name: ${{ inputs.release_name }}
      restore_db: ${{ inputs.restore_db }}
      restore_code: ${{ inputs.restore_code }}
```

## Inputs des workflows

### `promote.yml`

| Input | Type | Défaut | Description |
|-------|------|--------|-------------|
| `confirm` | string | — (requis) | Doit valoir `DEPLOY` |
| `sync_database` | boolean | `true` | Inclure la BDD (search-replace auto) |
| `sync_uploads` | boolean | `true` | Inclure les uploads (médias) |
| `dry_run` | boolean | `false` | Simulation (rsync -n, pas d'import DB) |
| `workflows_ref` | string | `v1` | Tag/SHA de tv-deploy-workflows pour charger les scripts |
| `layout` | string | `classic` | Layout du projet : `classic` ou `bedrock` (voir ci-dessous) |

### `rollback.yml`

| Input | Type | Défaut | Description |
|-------|------|--------|-------------|
| `confirm` | string | — (requis) | Doit valoir `ROLLBACK` |
| `release_name` | string | — (requis) | Nom du dossier release (ex: `tech-o.pro_2026-05-28_103256`) |
| `restore_db` | boolean | `true` | Restaurer la base de données |
| `restore_code` | boolean | `true` | Restaurer le code (sans uploads) |
| `workflows_ref` | string | `v1` | Tag/SHA de tv-deploy-workflows pour charger les scripts |
| `layout` | string | `classic` | Layout du projet : `classic` ou `bedrock` (voir ci-dessous) |

## Layout `classic` vs `bedrock`

- **`classic`** (défaut, projets `techvibes-wp-import-existing`) : `STAGING_PATH`/`PROD_PATH` pointent un `httpdocs/` qui contient directement `wp-admin/`, `wp-content/`, `wp-config.php`. C'est le comportement historique — les stubs existants qui n'envoient pas l'input `layout` ne changent pas.
- **`bedrock`** (projets `techvibes-wp-boilerplate`) : `STAGING_PATH`/`PROD_PATH` pointent la **racine du projet Bedrock** (qui contient `web/` = docroot avec `web/wp/` core et `web/app/` contenu, `config/`, `vendor/`, `composer.json`, `wp-cli.yml`, `.env`). Conséquences :
  - le rsync de promotion ne pousse que `web/ config/ vendor/ composer.json composer.lock wp-cli.yml` — le `.env` prod n'est **jamais** écrasé ;
  - les excludes backup/rsync visent `web/app/{uploads,cache,upgrade,wflogs}` au lieu de `wp-content/*` ;
  - toutes les commandes WP-CLI sont exécutées via `cd <PATH> && wp …` (le `wp-cli.yml` à la racine pointe `path: web/wp` ; `wp --path=` ne marche pas en Bedrock).

Stub côté client Bedrock : ajouter `layout: bedrock` dans le bloc `with:` des deux stubs.

## Secrets requis côté repo client

`secrets: inherit` propage automatiquement les secrets du repo client au workflow réutilisable.

| Secret | Description | Obligatoire |
|--------|-------------|-------------|
| `STAGING_SSH_KEY` | Clé SSH privée `github-actions-deploy` (autorisée sur staging ET prod) | ✅ |
| `STAGING_HOST` | Hôte du serveur staging (ex: `tv-staging.ma`) | ✅ (promote) |
| `STAGING_USER` | Utilisateur SSH staging (ex: `techvibes`) | ✅ (promote) |
| `STAGING_PATH` | Chemin httpdocs staging (racine projet Bedrock si `layout: bedrock`) | ✅ (promote) |
| `STAGING_SSH_PORT` | Port SSH staging | ❌ (défaut 22) |
| `PROD_HOST` | Hôte serveur prod client | ✅ |
| `PROD_USER` | Utilisateur SSH prod | ✅ |
| `PROD_PATH` | Chemin httpdocs prod (ex: `/var/www/vhosts/.../tech-o.pro/httpdocs` ; racine projet Bedrock si `layout: bedrock`) | ✅ |
| `PROD_SSH_PORT` | Port SSH prod | ❌ (défaut 22) |
| `TELEGRAM_BOT_URL` | URL du bot Telegram pour notifs | ❌ |
| `TELEGRAM_CHAT_ID` | Chat ID Telegram | ❌ |

## Versionnement

Convention semver, via tags Git :

- `v1` : version stable courante. Les stubs clients référencent `@v1`.
- `v1.0.1` : fix interne sans breaking change (les stubs `@v1` en bénéficient automatiquement).
- `v2` : breaking change (nouveau input requis, suppression d'un secret, etc.). Les stubs doivent être migrés un par un vers `@v2`.

Un breaking change typique : modifier la sémantique d'un input existant, exiger un nouveau secret, changer le format des releases backup.

## Migration d'un projet existant

Étapes pour migrer un projet qui a actuellement ses workflows en local (ex: `deploy-staging-to-prod.yml` + `rollback-prod.yml` + `resources/scripts/promote-*.sh`) :

1. **Créer les 2 stubs** (voir exemples ci-dessus) dans `.github/workflows/`.
2. **Supprimer l'ancien workflow** local (remplacé par le stub).
3. **Tester en dry_run** : déclencher manuellement le stub `deploy-staging-to-prod.yml` avec `confirm=DEPLOY`, `dry_run=true`.
4. **Si OK** : supprimer aussi les anciens scripts `resources/scripts/promote-*.sh` (ils sont maintenant dans `tv-deploy-workflows/scripts/`).
5. Commit + push.

## Pin SHA pour la prod (recommandé)

Une fois validé en `@v1`, pour figer la version d'un projet critique :

```bash
# Récupère le SHA du tag v1
gh api repos/TechvibesDigital/tv-deploy-workflows/git/refs/tags/v1 \
  --jq '.object.sha'
```

Puis dans le stub :
```yaml
uses: TechvibesDigital/tv-deploy-workflows/.github/workflows/promote.yml@<sha>
```

Avantage : immuable, immunisé contre une republication de tag.

## Structure du repo

```
tv-deploy-workflows/
├── .github/
│   └── workflows/
│       ├── promote.yml          # promotion staging→prod (workflow_call)
│       └── rollback.yml         # restauration release (workflow_call)
├── scripts/
│   ├── promote-prod-backup.sh   # sur prod : DB + tar code dans releases/
│   ├── promote-rsync.sh         # sur staging : rsync direct vers prod
│   ├── promote-db.sh            # sur staging : pipe DB → prod (sanitize collations)
│   ├── promote-prod-postdeploy.sh # sur prod : search-replace + caches
│   └── promote-rollback.sh      # sur prod : extract release + import DB
├── .gitignore
└── README.md
```

## Pré-requis côté infra

- Le serveur staging doit pouvoir SSH vers la prod (firewall client). Sinon → transit par le runner (autre design, à implémenter si besoin).
- Plesk côté prod : la clé `github-actions-deploy` doit être autorisée dans `~/.ssh/authorized_keys` du user prod.
- `bash -lc` est utilisé partout côté distant car en SSH non-interactif sur Plesk, `php`/`wp` ne sont pas dans le PATH (login shell requis).
