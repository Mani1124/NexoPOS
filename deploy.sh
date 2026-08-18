#!/bin/bash
set -euo pipefail

# Deploy script for MPOS (NexoPOS fork) on a WHM/VPS.
# Safe to run multiple times: every step checks existing state.
#
# Optional overrides:
#   APP_DIR        path to the application (default: script directory)
#   PHP_BIN        php binary (default: php)
#   COMPOSER_BIN   composer binary (default: composer)
#   WEB_USER       user owning storage files (default: www-data)
#   SKIP_ASSETS=1  skip npm install + build
#   GIT_PULL=1     pull latest code from git before deploying
#   GIT_TAG=...    deploy a specific git tag/branch (implies GIT_PULL)
#   NO_CACHE=1     skip config/route/view cache (useful during debugging)
#
# Usage: bash deploy.sh [tag]

APP_DIR="${APP_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
GIT_TAG="${GIT_TAG:-${1:-}}"
PHP_BIN="${PHP_BIN:-php}"
COMPOSER_BIN="${COMPOSER_BIN:-composer}"
NODE_BIN="${NODE_BIN:-node}"
NPM_BIN="${NPM_BIN:-npm}"
WEB_USER="${WEB_USER:-www-data}"
ENV_FILE="$APP_DIR/.env"
ENV_EXAMPLE="$APP_DIR/.env.example"
LOCK_FILE="$APP_DIR/.deploy.lock"

if [ -f "$LOCK_FILE" ]; then
    echo "==> A previous deploy appears to be running ($LOCK_FILE)."
    echo "    If not, remove it and rerun."
    exit 1
fi
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

echo "==> Checking prerequisites"
cd "$APP_DIR"

if [ ! -f "$APP_DIR/artisan" ]; then
    echo "ERROR: artisan not found in $APP_DIR. Aborting."
    exit 1
fi

"$PHP_BIN" -l "$APP_DIR/artisan" >/dev/null 2>&1 || {
    echo "ERROR: PHP is not working ($PHP_BIN). Aborting."
    exit 1
}

"$PHP_BIN" -r 'exit(version_compare(PHP_VERSION, "8.1.0", ">=") ? 0 : 1);' || {
    echo "ERROR: PHP >= 8.1 is required (PHP 8.4 recommended). Aborting."
    exit 1
}

echo "==> Pulling latest code"
if [ -n "$GIT_TAG" ]; then
    if [ ! -d "$APP_DIR/.git" ]; then
        echo "ERROR: no git repository found in $APP_DIR to checkout tag '$GIT_TAG'."
        exit 1
    fi
    git fetch --tags --quiet
    if git rev-parse --verify "refs/tags/$GIT_TAG" >/dev/null 2>&1; then
        git checkout --force "refs/tags/$GIT_TAG"
        echo "    checked out tag: $GIT_TAG"
    elif git rev-parse --verify "refs/heads/$GIT_TAG" >/dev/null 2>&1; then
        git checkout --force "$GIT_TAG"
        git pull --ff-only
        echo "    checked out branch: $GIT_TAG"
    else
        echo "ERROR: tag/branch '$GIT_TAG' not found. Aborting."
        exit 1
    fi
elif [ "${GIT_PULL:-0}" = "1" ] && [ -d "$APP_DIR/.git" ]; then
    git fetch --quiet
    git pull --ff-only
else
    echo "    skipped (set GIT_PULL=1 or pass a tag to enable)"
fi

echo "==> Installing PHP dependencies"
if [ -f "$APP_DIR/composer.lock" ]; then
    "$COMPOSER_BIN" install --no-interaction --prefer-dist --no-dev --optimize-autoloader \
        || "$COMPOSER_BIN" install --no-interaction --prefer-dist --optimize-autoloader
else
    "$COMPOSER_BIN" install --no-interaction --prefer-dist
fi

echo "==> Setting up .env"
if [ ! -f "$ENV_FILE" ]; then
    if [ ! -f "$ENV_EXAMPLE" ]; then
        echo "ERROR: .env.example not found. Aborting."
        exit 1
    fi
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    echo "    created .env from .env.example"
else
    echo "    .env already exists, keeping it"
fi

if ! grep -q '^APP_KEY=base64:' "$ENV_FILE" || grep -q '^APP_KEY=$' "$ENV_FILE"; then
    echo "==> Generating application key"
    "$PHP_BIN" artisan key:generate --force
else
    echo "==> Application key already set"
fi

echo "==> Running database migrations"
"$PHP_BIN" artisan migrate --force

echo "==> Linking storage"
if [ -L "$APP_DIR/public/storage" ] || [ -d "$APP_DIR/public/storage" ]; then
    echo "    storage link already exists"
else
    "$PHP_BIN" artisan storage:link
fi

echo "==> Fixing permissions"
chmod -R u+rwX,g+rwX "$APP_DIR/storage" "$APP_DIR/bootstrap/cache"
chown -R "$WEB_USER":"$WEB_USER" "$APP_DIR/storage" "$APP_DIR/bootstrap/cache" 2>/dev/null \
    || echo "    WARNING: chown to $WEB_USER failed - run as root or set WEB_USER"
chmod -R u+rwX,g+rwX "$APP_DIR/public" 2>/dev/null || true

echo "==> Building frontend assets"
if [ "${SKIP_ASSETS:-0}" = "1" ]; then
    echo "    skipped (SKIP_ASSETS=1)"
elif ! command -v "$NODE_BIN" >/dev/null 2>&1; then
    echo "    skipped (node not available)"
else
    if [ ! -d "$APP_DIR/node_modules" ]; then
        "$NPM_BIN" install --no-audit --no-fund
    else
        echo "    node_modules present, skipping npm install"
    fi
    "$NPM_BIN" run build
fi

echo "==> Caching application"
if [ "${NO_CACHE:-0}" = "1" ]; then
    "$PHP_BIN" artisan config:clear
    "$PHP_BIN" artisan route:clear
    "$PHP_BIN" artisan view:clear
    echo "    caches cleared (NO_CACHE=1)"
else
    "$PHP_BIN" artisan config:cache
    "$PHP_BIN" artisan route:cache
    "$PHP_BIN" artisan view:cache
fi

echo ""
echo "Deploy finished. Remaining manual steps (one-time, in WHM/cPanel):"
echo "  - Point the document root of your site/subdomain to:  $APP_DIR/public"
echo "  - Review $ENV_FILE: APP_URL, DB_* credentials, SANCTUM_STATEFUL_DOMAINS"
echo "  - Make sure HTTPS is active (AutoSSL)"