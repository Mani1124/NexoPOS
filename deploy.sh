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
TTY="${TTY:-/dev/tty}"

HAS_TTY=0
if { exec 3<> "$TTY"; } 2>/dev/null; then
    HAS_TTY=1
fi

if [ "${DEPLOY_REEXEC:-0}" != "1" ]; then
    if [ -f "$LOCK_FILE" ]; then
        echo "==> A previous deploy appears to be running ($LOCK_FILE)."
        echo "    If not, remove it and rerun."
        exit 1
    fi
fi
trap 'rm -f "$LOCK_FILE"' EXIT
touch "$LOCK_FILE"

TTY="${TTY:-/dev/tty}"

prompt_value() {
    local label="$1" default="$2" input=""
    if [ "$HAS_TTY" = "1" ]; then
        printf '    %s [%s]: ' "$label" "$default" >&2
        read -r input <&3 || input=""
    else
        read -r input || input=""
    fi
    echo "${input:-$default}"
}

prompt_required() {
    local label="$1" input="" attempts=0
    while [ "$attempts" -lt 20 ]; do
        attempts=$((attempts + 1))
        if [ "$HAS_TTY" = "1" ]; then
            printf '    %s: ' "$label" >&2
            read -r input <&3 || input=""
        else
            read -r input || input=""
        fi
        if [ -n "$input" ]; then
            echo "$input"
            return 0
        fi
        echo "    Value is required for $label." >&2
    done
    echo "ERROR: no value provided for $label after $attempts attempts. Aborting." >&2
    exit 1
}

set_env_value() {
    local key="$1" value="$2" escaped
    escaped="$(printf '%s' "$value" | sed 's/[\/&|\\]/\\&/g')"

    if grep -q "^${key}=" "$ENV_FILE"; then
        sed -i.bak "s|^${key}=.*|${key}=${escaped}|" "$ENV_FILE"
        rm -f "$ENV_FILE.bak"
    else
        printf '%s=%s\n' "$key" "$value" >> "$ENV_FILE"
    fi
}

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
if [ "${DEPLOY_REEXEC:-0}" = "1" ]; then
    echo "    (re-executed after checkout, skipping git step)"
elif [ -n "$GIT_TAG" ]; then
    if [ ! -d "$APP_DIR/.git" ]; then
        echo "ERROR: no git repository found in $APP_DIR to checkout tag '$GIT_TAG'."
        exit 1
    fi
    git fetch --tags --quiet 2>/dev/null \
        || echo "    WARNING: unable to fetch from remote. Using local refs only."
    if git rev-parse --verify "refs/tags/$GIT_TAG" >/dev/null 2>&1; then
        echo "    checking out tag: $GIT_TAG"
        git checkout --force "refs/tags/$GIT_TAG" 2>&1 || {
            echo "ERROR: could not check out tag '$GIT_TAG'."
            echo "       This usually happens when untracked files (e.g. public/build or generated files)"
            echo "       would be overwritten by the checkout. Move them aside and rerun,"
            echo "       or add them to .gitignore."
            exit 1
        }
        echo "    checked out tag: $GIT_TAG"
        echo "    deploy.sh may have changed - re-executing with the new version..."
        export DEPLOY_REEXEC=1
        exec bash "$0" "$@"
    elif git rev-parse --verify "refs/heads/$GIT_TAG" >/dev/null 2>&1; then
        echo "    checking out branch: $GIT_TAG"
        git checkout --force "$GIT_TAG" 2>&1 || {
            echo "ERROR: could not check out branch '$GIT_TAG'. See message above."
            exit 1
        }
        git pull --ff-only 2>&1 || echo "    WARNING: could not pull latest changes for branch '$GIT_TAG'."
        echo "    checked out branch: $GIT_TAG"
        echo "    deploy.sh may have changed - re-executing with the new version..."
        export DEPLOY_REEXEC=1
        exec bash "$0" "$@"
    else
        echo "ERROR: tag/branch '$GIT_TAG' not found."
        echo "       Run 'git tag' to list available tags."
        exit 1
    fi
elif [ "${GIT_PULL:-0}" = "1" ] && [ -d "$APP_DIR/.git" ]; then
    git fetch --quiet 2>&1 || echo "    WARNING: unable to fetch from remote."
    git pull --ff-only 2>&1 || {
        echo "ERROR: git pull failed. See message above."
        exit 1
    }
    echo "    deploy.sh may have changed - re-executing with the new version..."
    export DEPLOY_REEXEC=1
    exec bash "$0" "$@"
else
    echo "    skipped (set GIT_PULL=1 or pass a tag to enable)"
fi

env_is_placeholder() {
    [ "$(grep '^DB_DATABASE=' "$ENV_FILE" | cut -d= -f2-)" = "laravel" ] &&
    [ "$(grep '^DB_USERNAME=' "$ENV_FILE" | cut -d= -f2-)" = "root" ] &&
    [ -z "$(grep '^DB_PASSWORD=' "$ENV_FILE" | cut -d= -f2-)" ]
}

echo "==> Setting up .env"
if [ ! -f "$ENV_FILE" ] || env_is_placeholder; then
    if [ ! -f "$ENV_FILE" ]; then
        if [ ! -f "$ENV_EXAMPLE" ]; then
            echo "ERROR: .env.example not found. Aborting."
            exit 1
        fi
        cp "$ENV_EXAMPLE" "$ENV_FILE"
        echo "    created .env from .env.example"
    else
        echo "    .env uses placeholder database settings, reconfiguring..."
    fi

    if [ "$HAS_TTY" = "1" ]; then
        echo "==> Configure .env (press Enter to accept the default):"
        set_env_value 'APP_NAME' "$(prompt_value 'APP_NAME' 'MPOS')"
        set_env_value 'APP_ENV' "$(prompt_value 'APP_ENV' 'production')"
        set_env_value 'APP_DEBUG' "$(prompt_value 'APP_DEBUG' 'false')"
        set_env_value 'APP_URL' "$(prompt_required 'APP_URL')"
        set_env_value 'DB_CONNECTION' "$(prompt_value 'DB_CONNECTION' 'mysql')"
        set_env_value 'DB_HOST' "$(prompt_value 'DB_HOST' '127.0.0.1')"
        set_env_value 'DB_PORT' "$(prompt_value 'DB_PORT' '3306')"
        set_env_value 'DB_DATABASE' "$(prompt_required 'DB_DATABASE')"
        set_env_value 'DB_USERNAME' "$(prompt_required 'DB_USERNAME')"
        set_env_value 'DB_PASSWORD' "$(prompt_required 'DB_PASSWORD')"
        set_env_value 'SESSION_DOMAIN' "$(prompt_value 'SESSION_DOMAIN' '')"
        set_env_value 'SANCTUM_STATEFUL_DOMAINS' "$(prompt_value 'SANCTUM_STATEFUL_DOMAINS' 'localhost,127.0.0.1')"
        echo "    .env configured."
    else
        echo "    no terminal available for prompting; .env left from .env.example."
        echo "    Edit $ENV_FILE manually (set DB_DATABASE, DB_USERNAME, DB_PASSWORD, APP_URL),"
        echo "    then rerun ./deploy.sh."
    fi
else
    echo "    .env already configured, keeping it"
fi

if ! grep -q '^APP_KEY=base64:' "$ENV_FILE" || grep -q '^APP_KEY=$' "$ENV_FILE"; then
    echo "==> Generating application key"
    "$PHP_BIN" artisan key:generate --force
else
    echo "==> Application key already set"
fi

echo "==> Installing PHP dependencies"
if [ -f "$APP_DIR/composer.lock" ]; then
    "$COMPOSER_BIN" install --no-interaction --prefer-dist --no-dev --optimize-autoloader \
        || "$COMPOSER_BIN" install --no-interaction --prefer-dist --optimize-autoloader
else
    "$COMPOSER_BIN" install --no-interaction --prefer-dist
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