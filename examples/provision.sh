#!/usr/bin/env bash
# provision.sh — create a disposable Frappe bench from a track branch.
#
# A disposable bench never uses a shared app checkout. The script creates a
# Git development worktree under TRACK_DIR, then clones the selected branch into
# bench/apps/APP as a separate normal checkout. The registry records both paths
# so teardown can remove them together.

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
SOURCE_REPO="${SOURCE_REPO:-}"
APP_NAME="${APP_NAME:-}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
SIGNED_BY="${SIGNED_BY:-${USER:-unknown}}"
DRY_RUN=false
FROM_REFERENCE=false
# =======================================================

usage() {
  cat <<EOF
Usage: $0 --name <bench-name> --branch <branch> --track-dir <track-dir> [options]

Options:
  --name <name>        Bench name (required)
  --branch <branch>    Git branch to checkout (required)
  --track-dir <path>   Owning track directory (required)
  --source-repo <path> Local Git repository used to create the worktree
  --worktree <path>    Worktree output path; must be inside --track-dir
  --app <app-name>     Frappe app name (default: APP_NAME env var)
  --from-reference     Restore data from reference bench instead of empty site
  --dry-run            Print actions without executing
  --help               Show this help

APP_REPO may be a Git URL. When --source-repo is omitted for a URL, a bare
source clone is kept under BENCH_ROOT/.sources and the worktree remains under
the owning track.
EOF
}

log() { echo "[provision] $*"; }
dry() { if [ "$DRY_RUN" = true ]; then echo "[DRY-RUN] $*"; else "$@"; fi; }

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $1" >&2
    exit 1
  }
}

abs_existing_dir() {
  (cd "$1" && pwd -P)
}

path_is_inside() {
  case "$1" in
    "$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Parse args
NAME=""
BRANCH=""
TRACK_DIR="${TRACK_DIR:-}"
WORKTREE=""
APP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --track-dir) TRACK_DIR="$2"; shift 2 ;;
    --source-repo) SOURCE_REPO="$2"; shift 2 ;;
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
[ -z "$TRACK_DIR" ] && { echo "ERROR: --track-dir is required" >&2; usage; exit 1; }
APP="${APP:-$APP_NAME}"
[ -z "$APP" ] && { echo "ERROR: --app or APP_NAME is required" >&2; usage; exit 1; }

require_command git
require_command jq

if [ "$NAME" = "$REFERENCE_BENCH_NAME" ]; then
  echo "ERROR: refusing to provision over reference bench '$REFERENCE_BENCH_NAME'" >&2
  exit 1
fi

if [ ! -d "$TRACK_DIR" ]; then
  echo "ERROR: track directory does not exist: $TRACK_DIR" >&2
  exit 1
fi
TRACK_DIR=$(abs_existing_dir "$TRACK_DIR")

BENCH_DIR="${BENCH_ROOT}/${NAME}"
SITE_NAME="${NAME}.local"
DB_NAME="${NAME//-/_}"
DB_USER="${NAME//-/_}"
DB_PASSWORD="$(openssl rand -hex 16)"
WORKTREE="${WORKTREE:-${TRACK_DIR}/worktrees/${NAME}/${APP}}"

if [[ "$WORKTREE" != /* ]]; then
  WORKTREE="${TRACK_DIR}/${WORKTREE}"
fi
if ! path_is_inside "$WORKTREE" "$TRACK_DIR"; then
  echo "ERROR: worktree must be inside track directory: $TRACK_DIR" >&2
  exit 1
fi

# Resolve or create a private source repository. A local source checkout is
# only used as the worktree source; it is never mounted into the bench.
if [ -z "$SOURCE_REPO" ]; then
  if [ -n "$APP_REPO" ] && [ -d "$APP_REPO" ]; then
    SOURCE_REPO="$APP_REPO"
  elif [ -n "$APP_REPO" ]; then
    SOURCE_REPO="${BENCH_ROOT}/.sources/${APP}.git"
    if [ ! -d "$SOURCE_REPO" ]; then
      if [ "$DRY_RUN" = true ]; then
        log "would clone source repository $APP_REPO into $SOURCE_REPO"
      else
        mkdir -p "$(dirname "$SOURCE_REPO")"
        git clone --bare "$APP_REPO" "$SOURCE_REPO"
      fi
    fi
  else
    echo "ERROR: --source-repo or APP_REPO is required" >&2
    exit 1
  fi
fi

if [ ! -d "$SOURCE_REPO" ] || ! git -C "$SOURCE_REPO" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: source repository is not a Git repository: $SOURCE_REPO" >&2
  exit 1
fi
SOURCE_REPO=$(cd "$SOURCE_REPO" && pwd -P)

# Allocate next index n (0 reserved for reference), under the registry lock.
mkdir -p "$BENCH_ROOT"
LOCK_FILE="${BENCH_ROOT}/.registry.lock"
exec 200>"$LOCK_FILE"
flock -x 200
if [ ! -f "$REGISTRY_FILE" ] && [ "$DRY_RUN" = false ]; then
  echo '{"version":1,"bench_root":"'"$BENCH_ROOT"'","reference_bench_name":"'"$REFERENCE_BENCH_NAME"'","benches":{}}' > "$REGISTRY_FILE"
fi

N=1
while true; do
  WEB_PORT=$((WEBSERVER_BASE_PORT + N))
  SOCK_PORT=$((SOCKETIO_BASE_PORT + N))
  WATCH_PORT=$((FILE_WATCHER_BASE_PORT + N))
  conflict=""
  if [ -f "$REGISTRY_FILE" ]; then
    conflict=$(jq -r --argjson p "$WEB_PORT" '.benches[] | select(.ports.webserver == $p) | .name' "$REGISTRY_FILE" 2>/dev/null || true)
  fi
  [ -z "$conflict" ] && break
  N=$((N + 1))
done

REDIS_CACHE_DB=$N
REDIS_QUEUE_DB=$N
REDIS_SOCKETIO_DB=$N

log "Provisioning bench '$NAME' (branch: $BRANCH, app: $APP)"
log "  track: $TRACK_DIR"
log "  worktree: $WORKTREE"
log "  source: $SOURCE_REPO"
log "  ports: web=$WEB_PORT socketio=$SOCK_PORT watcher=$WATCH_PORT"
log "  redis DBs: cache=$REDIS_CACHE_DB queue=$REDIS_QUEUE_DB socketio=$REDIS_SOCKETIO_DB"
log "  db: $DB_NAME / $DB_USER"

if [ "$DRY_RUN" = false ]; then
  if jq -e --arg name "$NAME" '.benches[$name]' "$REGISTRY_FILE" >/dev/null 2>&1; then
    existing_worktree=$(jq -r --arg name "$NAME" '.benches[$name].worktree // empty' "$REGISTRY_FILE")
    [ "$existing_worktree" = "$WORKTREE" ] || {
      flock -u 200
      echo "ERROR: bench '$NAME' already exists with a different worktree" >&2
      exit 1
    }
  else
    TMP=$(mktemp)
    jq --arg name "$NAME" \
       --arg path "$BENCH_DIR" \
       --arg site "$SITE_NAME" \
       --arg branch "$BRANCH" \
       --arg worktree "$WORKTREE" \
       --arg track "$TRACK_DIR" \
       --arg source "$SOURCE_REPO" \
       --arg app "$APP" \
       --arg signer "$SIGNED_BY" \
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
          name: $name, path: $path, site_name: $site, branch: $branch,
          worktree: $worktree, track_dir: $track, source_repo: $source,
          worktree_managed: true, app_name: $app,
          bench_app_checkout: ($path + "/apps/" + $app),
          purpose: "Provisioned by provision.sh",
          ports: {webserver: $web, socketio: $sock, file_watcher: $watch},
          redis: {cache_db: $cache, queue_db: $queue, socketio_db: $socket},
          database: {db_name: $db, db_user: $user, db_password: $pass},
          status: "provisioning", created_at: now | todate,
          created_by: $signer
        }' "$REGISTRY_FILE" > "$TMP"
    mv "$TMP" "$REGISTRY_FILE"
  fi
fi
flock -u 200

WORKTREE_CREATED=false
cleanup_partial() {
  if [ "$DRY_RUN" = false ] && [ "$WORKTREE_CREATED" = true ]; then
    log "Rolling back managed worktree: $WORKTREE"
    git -C "$SOURCE_REPO" worktree remove --force "$WORKTREE" || true
  fi
}
trap cleanup_partial ERR

if [ -e "$WORKTREE" ]; then
  if ! git -C "$WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: existing worktree path is not a Git worktree: $WORKTREE" >&2
    exit 1
  fi
  log "Using existing managed worktree: $WORKTREE"
else
  if [ "$DRY_RUN" = true ]; then
    log "would create Git worktree $WORKTREE from $SOURCE_REPO at $BRANCH"
  else
    mkdir -p "$(dirname "$WORKTREE")"
    if git -C "$SOURCE_REPO" show-ref --verify --quiet "refs/heads/$BRANCH"; then
      git -C "$SOURCE_REPO" worktree add "$WORKTREE" "$BRANCH"
    elif git -C "$SOURCE_REPO" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
      git -C "$SOURCE_REPO" worktree add -b "$BRANCH" "$WORKTREE" "origin/$BRANCH"
    else
      echo "ERROR: branch not found in source repository: $BRANCH" >&2
      exit 1
    fi
    WORKTREE_CREATED=true
  fi
fi

# Create the bench, then clone the selected branch as its independent app
# checkout. The running bench must never point at the development worktree.
if [ -d "$BENCH_DIR" ]; then
  log "Bench directory exists; reusing (idempotent)"
else
  dry bench init --frappe-branch "$FRAPPE_BRANCH" "$BENCH_DIR"
fi

mkdir -p "$BENCH_DIR/apps"
APP_PATH="$BENCH_DIR/apps/$APP"
if [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; then
  [ ! -L "$APP_PATH" ] || {
    echo "ERROR: bench app path must be a normal Git checkout, not a symlink: $APP_PATH" >&2
    exit 1
  }
  current_branch=$(git -C "$APP_PATH" branch --show-current 2>/dev/null || true)
  [ "$current_branch" = "$BRANCH" ] || {
    echo "ERROR: bench app checkout is on '$current_branch', expected '$BRANCH': $APP_PATH" >&2
    exit 1
  }
else
  dry git clone --branch "$BRANCH" --single-branch "$SOURCE_REPO" "$APP_PATH"
  
  if [ "$DRY_RUN" = false ]; then
    echo "$APP" >> "$BENCH_DIR/sites/apps.txt"
  fi
  dry bench pip install -e "$APP_PATH"
fi

cd "$BENCH_DIR"

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

# Socket.io DNS Resolution Fix for Docker containers
if ! grep -q "$SITE_NAME" /etc/hosts 2>/dev/null; then
  log "Registering $SITE_NAME in container /etc/hosts for Socket.io authentication..."
  echo "127.0.0.1 $SITE_NAME" >> /etc/hosts 2>/dev/null || true
fi

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
  log "Restore from reference requested; follow SKILL.md §4.5 for backup selection."
fi

# Install app from the bench's branch checkout, never from the development
# worktree and never with a shared source path.
dry bench --site "$SITE_NAME" install-app "$APP"

log "Health check: run 'bench start' and curl http://127.0.0.1:${WEB_PORT}/api/method/ping"

if [ "$DRY_RUN" = false ]; then
  exec 200>"$LOCK_FILE"
  flock -x 200
  TMP=$(mktemp)
  jq --arg name "$NAME" '.benches[$name].status = "ready"' "$REGISTRY_FILE" > "$TMP"
  mv "$TMP" "$REGISTRY_FILE"
  flock -u 200
fi

trap - ERR
log "Provision complete for bench '$NAME'"
