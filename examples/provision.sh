#!/usr/bin/env bash
# provision.sh — create a disposable Frappe bench.
#
# This is a template. Adapt the configuration block below to your environment.
# Supports: fresh empty site, restore from reference bench, --dry-run.

set -euo pipefail

# ==================== CONFIGURATION ====================
BENCH_ROOT="${BENCH_ROOT:-/opt/benches}"
REFERENCE_BENCH_NAME="${REFERENCE_BENCH_NAME:-reference}"
REFERENCE_BENCH_DIR="${REFERENCE_BENCH_DIR:-${BENCH_ROOT}/${REFERENCE_BENCH_NAME}}"
REFERENCE_SITE="${REFERENCE_SITE:-main.local}"
REGISTRY_FILE="${REGISTRY_FILE:-${BENCH_ROOT}/registry.json}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-change-me}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
MARIADB_HOST="${MARIADB_HOST:-mariadb}"
REDIS_HOST="${REDIS_HOST:-redis}"
WEBSERVER_BASE_PORT="${WEBSERVER_BASE_PORT:-8080}"
SOCKETIO_BASE_PORT="${SOCKETIO_BASE_PORT:-9000}"
FILE_WATCHER_BASE_PORT="${FILE_WATCHER_BASE_PORT:-6787}"
APP_REPO="${APP_REPO:-}"
APP_NAME="${APP_NAME:-}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
DRY_RUN=false
FROM_REFERENCE=false
# =======================================================

usage() {
  cat <<EOF
Usage: $0 --name <bench-name> --branch <branch> [options]

Options:
  --name <name>        Bench name (required)
  --branch <branch>    Git branch to checkout (required)
  --worktree <path>    Local worktree path (default: clone from APP_REPO)
  --app <app-name>     Frappe app name (default: APP_NAME env var)
  --from-reference     Restore data from reference bench instead of empty site
  --dry-run            Print actions without executing
  --help               Show this help
EOF
}

log() { echo "[provision] $*"; }
dry() { if [ "$DRY_RUN" = true ]; then echo "[DRY-RUN] $*"; else "$@"; fi }

# Parse args
NAME=""
BRANCH=""
WORKTREE=""
APP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --from-reference) FROM_REFERENCE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[ -z "$NAME" ] && { echo "ERROR: --name is required" >&2; usage; exit 1; }
[ -z "$BRANCH" ] && { echo "ERROR: --branch is required" >&2; usage; exit 1; }
APP="${APP:-$APP_NAME}"
[ -z "$APP" ] && { echo "ERROR: --app or APP_NAME is required" >&2; usage; exit 1; }

if [ "$NAME" = "$REFERENCE_BENCH_NAME" ]; then
  echo "ERROR: refusing to provision over reference bench '$REFERENCE_BENCH_NAME'" >&2
  exit 1
fi

BENCH_DIR="${BENCH_ROOT}/${NAME}"
SITE_NAME="${NAME}.local"
DB_NAME="${NAME//-/_}"
DB_USER="${NAME//-/_}"
DB_PASSWORD="$(openssl rand -hex 16)"

# Allocate next index n (0 reserved for reference)
N=1
while true; do
  WEB_PORT=$((WEBSERVER_BASE_PORT + N))
  SOCK_PORT=$((SOCKETIO_BASE_PORT + N))
  WATCH_PORT=$((FILE_WATCHER_BASE_PORT + N))
  # check registry for conflicts
  if command -v jq >/dev/null 2>&1 && [ -f "$REGISTRY_FILE" ]; then
    conflict=$(jq -r --argjson p "$WEB_PORT" '.benches[] | select(.ports.webserver == $p) | .name' "$REGISTRY_FILE" 2>/dev/null || true)
    [ -z "$conflict" ] && break
  else
    break
  fi
  N=$((N + 1))
done

REDIS_CACHE_DB=$N
REDIS_QUEUE_DB=$N
REDIS_SOCKETIO_DB=$N

log "Provisioning bench '$NAME' (branch: $BRANCH, app: $APP)"
log "  ports: web=$WEB_PORT socketio=$SOCK_PORT watcher=$WATCH_PORT"
log "  redis DBs: cache=$REDIS_CACHE_DB queue=$REDIS_QUEUE_DB socketio=$REDIS_SOCKETIO_DB"
log "  db: $DB_NAME / $DB_USER"

# Lock registry
LOCK_FILE="${BENCH_ROOT}/.registry.lock"
exec 200>"$LOCK_FILE"
flock -x 200

# Write intent record
if [ "$DRY_RUN" = false ]; then
  mkdir -p "$BENCH_ROOT"
  if [ ! -f "$REGISTRY_FILE" ]; then
    echo '{"version":1,"bench_root":"'"$BENCH_ROOT"'","reference_bench_name":"'"$REFERENCE_BENCH_NAME"'","benches":{}}' > "$REGISTRY_FILE"
  fi
  TMP=$(mktemp)
  jq --arg name "$NAME" \
     --arg path "$BENCH_DIR" \
     --arg site "$SITE_NAME" \
     --arg branch "$BRANCH" \
     --arg worktree "$WORKTREE" \
     --argjson web "$WEB_PORT" \
     --argjson sock "$SOCK_PORT" \
     --argjson watch "$WATCH_PORT" \
     --argjson cache "$REDIS_CACHE_DB" \
     --argjson queue "$REDIS_QUEUE_DB" \
     --argjson socket "$REDIS_SOCKETIO_DB" \
     --arg db "$DB_NAME" \
     --arg user "$DB_USER" \
     --arg pass "$DB_PASSWORD" \
     '.benches[$name] = {
        name: $name, path: $path, site_name: $site, branch: $branch, worktree: $worktree,
        purpose: "Provisioned by provision.sh", ports: {webserver: $web, socketio: $sock, file_watcher: $watch},
        redis: {cache_db: $cache, queue_db: $queue, socketio_db: $socket},
        database: {db_name: $db, db_user: $user, db_password: $pass},
        status: "provisioning", created_at: now | todate, created_by: "provision.sh"
      }' "$REGISTRY_FILE" > "$TMP"
  mv "$TMP" "$REGISTRY_FILE"
fi
flock -u 200

# Create bench
if [ -d "$BENCH_DIR" ]; then
  log "Bench directory exists; reusing (idempotent)"
else
  dry bench init --frappe-branch "$FRAPPE_BRANCH" "$BENCH_DIR"
fi

cd "$BENCH_DIR"

# Get app
if [ -n "$WORKTREE" ]; then
  log "Using worktree: $WORKTREE"
  # link or copy worktree into apps/
else
  if [ -z "$APP_REPO" ]; then
    echo "ERROR: --worktree or APP_REPO is required to get app" >&2
    exit 1
  fi
  dry bench get-app "$APP_REPO" --branch "$BRANCH"
fi

# Configure
dry bench set-config -g db_host "$MARIADB_HOST"
dry bench set-config -g db_port 3306
dry bench set-config -g redis_cache "redis://${REDIS_HOST}:6379/${REDIS_CACHE_DB}"
dry bench set-config -g redis_queue "redis://${REDIS_HOST}:6379/${REDIS_QUEUE_DB}"
dry bench set-config -g redis_socketio "redis://${REDIS_HOST}:6379/${REDIS_SOCKETIO_DB}"
dry bench set-config -g webserver_port "$WEB_PORT"
dry bench set-config -g socketio_port "$SOCK_PORT"
dry bench set-config -g file_watcher_port "$WATCH_PORT"
dry bench set-config -g developer_mode 1
dry bench set-config -g serve_default_site true
dry bench set-config -g default_site "$SITE_NAME"

# Create DB/user
if [ "$DRY_RUN" = false ]; then
  mariadb -h "$MARIADB_HOST" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL
else
  echo "[DRY-RUN] would create database ${DB_NAME} and user ${DB_USER}"
fi

# Create site
if [ -d "sites/${SITE_NAME}" ]; then
  log "Site exists; reusing (idempotent)"
else
  dry bench new-site "$SITE_NAME" \
    --mariadb-root-username "$DB_ROOT_USER" \
    --mariadb-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --db-name "$DB_NAME" \
    --db-password "$DB_PASSWORD"
fi

if [ "$FROM_REFERENCE" = true ]; then
  log "Restoring from reference bench..."
  # TODO: locate latest backup from reference bench
  # dry bench --site "$SITE_NAME" --force restore "$BACKUP_SQL" ...
  # REFERENCE_KEY=$(grep -o '"encryption_key": *"[^"]*"' "${REFERENCE_BENCH_DIR}/sites/${REFERENCE_SITE}/site_config.json" | head -1 | cut -d'"' -f4)
  # dry bench --site "$SITE_NAME" set-config encryption_key "$REFERENCE_KEY"
  log "  (restore-from-reference not fully implemented in template; see SKILL.md)"
fi

# Install app
dry bench --site "$SITE_NAME" install-app "$APP"

# Health check placeholder
log "Health check: run 'bench start' and curl http://127.0.0.1:${WEB_PORT}/api/method/ping"

# Mark ready
if [ "$DRY_RUN" = false ]; then
  exec 200>"$LOCK_FILE"
  flock -x 200
  TMP=$(mktemp)
  jq --arg name "$NAME" '.benches[$name].status = "ready"' "$REGISTRY_FILE" > "$TMP"
  mv "$TMP" "$REGISTRY_FILE"
  flock -u 200
fi

log "Provision complete for bench '$NAME'"
