#!/usr/bin/env bash
# teardown.sh — remove a disposable Frappe bench, branch checkout, and worktree.
#
# This is a template. Adapt the configuration block below to your environment.
# Supports --dry-run. Refuses to touch the reference bench.

set -euo pipefail

# ==================== CONFIGURATION ====================
BENCH_ROOT="${BENCH_ROOT:-/opt/benches}"
REFERENCE_BENCH_NAME="${REFERENCE_BENCH_NAME:-reference}"
REGISTRY_FILE="${REGISTRY_FILE:-${BENCH_ROOT}/registry.json}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-change-me}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
MARIADB_HOST="${MARIADB_HOST:-mariadb}"
# Matches provision.sh's per-role defaults: many devcontainer compose setups
# do not publish a plain "redis" service. REDIS_HOST, if set, overrides all
# three roles uniformly (single-Redis setups).
REDIS_CACHE_HOST="${REDIS_HOST:-redis-cache}"
REDIS_QUEUE_HOST="${REDIS_HOST:-redis-queue}"
REDIS_SOCKETIO_HOST="${REDIS_HOST:-redis-queue}"
SIGNED_BY="${SIGNED_BY:-${USER:-unknown}}"
DRY_RUN=false
# =======================================================

usage() {
  cat <<EOF
Usage: $0 --name <bench-name> [--dry-run]

Options:
  --name <name>   Bench name to tear down (required)
  --dry-run       Print actions without executing
  --help          Show this help
EOF
}

log() { echo "[teardown] $*"; }

NAME=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

[ -z "$NAME" ] && { echo "ERROR: --name is required" >&2; usage; exit 1; }

if [ "$NAME" = "$REFERENCE_BENCH_NAME" ]; then
  echo "ERROR: refusing to teardown the reference bench '$REFERENCE_BENCH_NAME'" >&2
  exit 1
fi

BENCH_DIR="${BENCH_ROOT}/${NAME}"
LOCK_FILE="${BENCH_ROOT}/.registry.lock"

# Read registry entry
if [ ! -f "$REGISTRY_FILE" ]; then
  echo "ERROR: registry not found: $REGISTRY_FILE" >&2
  exit 1
fi

ENTRY=$(jq -r --arg name "$NAME" '.benches[$name] // empty' "$REGISTRY_FILE")
if [ -z "$ENTRY" ]; then
  echo "ERROR: bench '$NAME' not found in registry" >&2
  exit 1
fi

command -v git >/dev/null 2>&1 || {
  echo "ERROR: required command not found: git" >&2
  exit 1
}

SITE_NAME=$(echo "$ENTRY" | jq -r '.site_name')
DB_NAME=$(echo "$ENTRY" | jq -r '.database.db_name')
DB_USER=$(echo "$ENTRY" | jq -r '.database.db_user')
REDIS_CACHE_DB=$(echo "$ENTRY" | jq -r '.redis.cache_db')
REDIS_QUEUE_DB=$(echo "$ENTRY" | jq -r '.redis.queue_db')
REDIS_SOCKETIO_DB=$(echo "$ENTRY" | jq -r '.redis.socketio_db')
PID=$(echo "$ENTRY" | jq -r '.pid // empty')
WORKTREE=$(echo "$ENTRY" | jq -r '.worktree // empty')
SOURCE_REPO=$(echo "$ENTRY" | jq -r '.source_repo // empty')
TRACK_DIR=$(echo "$ENTRY" | jq -r '.track_dir // empty')
WORKTREE_MANAGED=$(echo "$ENTRY" | jq -r '.worktree_managed // false')
BENCH_APP_CHECKOUT=$(echo "$ENTRY" | jq -r '.bench_app_checkout // empty')

if [ "$WORKTREE_MANAGED" = "true" ]; then
  [ -n "$WORKTREE" ] && [ -n "$SOURCE_REPO" ] && [ -n "$TRACK_DIR" ] || {
    echo "ERROR: registry entry lacks managed worktree metadata" >&2
    exit 1
  }
  case "$WORKTREE" in
    "$TRACK_DIR"/*) ;;
    *) echo "ERROR: refusing worktree outside track directory: $WORKTREE" >&2; exit 1 ;;
  esac
  [ -d "$SOURCE_REPO" ] && git -C "$SOURCE_REPO" rev-parse --git-dir >/dev/null 2>&1 || {
    echo "ERROR: source repository is unavailable: $SOURCE_REPO" >&2
    exit 1
  }
fi

log "Tearing down bench '$NAME'"
log "  site: $SITE_NAME, db: $DB_NAME / $DB_USER"
log "  redis DBs: $REDIS_CACHE_DB $REDIS_QUEUE_DB $REDIS_SOCKETIO_DB"

# Lock registry
exec 200>"$LOCK_FILE"
flock -x 200

# Mark stopping
if [ "$DRY_RUN" = false ]; then
  TMP=$(mktemp)
  jq --arg name "$NAME" '.benches[$name].status = "stopping"' "$REGISTRY_FILE" > "$TMP"
  mv "$TMP" "$REGISTRY_FILE"
fi
flock -u 200

# Stop process
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  log "Stopping process $PID"
  if [ "$DRY_RUN" = false ]; then
    kill -TERM "$PID" || true
    sleep 5
    kill -KILL "$PID" 2>/dev/null || true
  else
    echo "[DRY-RUN] would kill $PID"
  fi
fi

# Also kill any remaining processes referencing this bench dir
if [ "$DRY_RUN" = false ]; then
  pgrep -f "$BENCH_DIR" 2>/dev/null | xargs -r kill -TERM 2>/dev/null || true
  sleep 3
  pgrep -f "$BENCH_DIR" 2>/dev/null | xargs -r kill -KILL 2>/dev/null || true
else
  echo "[DRY-RUN] would kill processes matching $BENCH_DIR"
fi

# Drop database and user
if [ "$DRY_RUN" = false ]; then
  if ! mariadb -h "$MARIADB_HOST" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
    cat >&2 <<EOF
ERROR: cannot authenticate to MariaDB at ${MARIADB_HOST} as ${DB_ROOT_USER}.
DB_ROOT_PASSWORD is unset or wrong (currently defaults to the placeholder
"change-me" unless overridden). Find the real password from the host with:
  docker inspect -f '{{range .Config.Env}}{{if eq (index (split . "=") 0) "MYSQL_ROOT_PASSWORD"}}{{index (split . "=") 1}}{{end}}{{end}}' <mariadb-container-name>
then re-run with DB_ROOT_PASSWORD=<password> in the environment.
EOF
    exit 1
  fi
  mariadb -h "$MARIADB_HOST" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" \
    -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`; DROP USER IF EXISTS '${DB_USER}'@'%'; FLUSH PRIVILEGES;"
else
  echo "[DRY-RUN] would drop database $DB_NAME and user $DB_USER"
fi

# Flush Redis DBs (each role may live on a different host)
if [ "$DRY_RUN" = false ]; then
  redis-cli -h "$REDIS_CACHE_HOST" -n "$REDIS_CACHE_DB" FLUSHDB
  redis-cli -h "$REDIS_QUEUE_HOST" -n "$REDIS_QUEUE_DB" FLUSHDB
  redis-cli -h "$REDIS_SOCKETIO_HOST" -n "$REDIS_SOCKETIO_DB" FLUSHDB
else
  echo "[DRY-RUN] would flush redis DBs: cache=${REDIS_CACHE_HOST}/${REDIS_CACHE_DB} queue=${REDIS_QUEUE_HOST}/${REDIS_QUEUE_DB} socketio=${REDIS_SOCKETIO_HOST}/${REDIS_SOCKETIO_DB}"
fi

# Remove bench directory
if [ -d "$BENCH_DIR" ]; then
  if [ "$DRY_RUN" = false ]; then
    rm -rf "$BENCH_DIR"
  else
    echo "[DRY-RUN] would remove directory $BENCH_DIR"
  fi
fi

# Remove the development worktree through Git. The bench app checkout was
# removed with BENCH_DIR above; it is intentionally not the worktree path.
WORKTREE_REMOVED=true
if [ "$WORKTREE_MANAGED" = "true" ]; then
  if [ "$DRY_RUN" = false ]; then
    if [ -e "$WORKTREE" ]; then
      log "Removing development worktree $WORKTREE"
      if ! git -C "$SOURCE_REPO" worktree remove --force "$WORKTREE"; then
        WORKTREE_REMOVED=false
      fi
    else
      log "Development worktree already absent: $WORKTREE"
    fi
  else
    echo "[DRY-RUN] would remove Git worktree $WORKTREE from $SOURCE_REPO"
  fi
fi

if [ "$WORKTREE_REMOVED" != true ]; then
  echo "ERROR: bench removed but development worktree cleanup failed; registry retained" >&2
  exec 200>"$LOCK_FILE"
  flock -x 200
  TMP=$(mktemp)
  jq --arg name "$NAME" '.benches[$name].status = "failed" | .benches[$name].cleanup_error = "worktree removal failed"' "$REGISTRY_FILE" > "$TMP"
  mv "$TMP" "$REGISTRY_FILE"
  flock -u 200
  exit 1
fi

# Remove registry entry
exec 200>"$LOCK_FILE"
flock -x 200
if [ "$DRY_RUN" = false ]; then
  TMP=$(mktemp)
  jq --arg name "$NAME" --arg signer "$SIGNED_BY" \
    '.archive = ((.archive // []) + [(.benches[$name] + {torn_down_at: (now | todate), torn_down_by: $signer, worktree_removed: true, outcome: "clean"})]) | del(.benches[$name])' \
    "$REGISTRY_FILE" > "$TMP"
  mv "$TMP" "$REGISTRY_FILE"
else
  echo "[DRY-RUN] would remove registry entry for $NAME"
fi
flock -u 200

log "Teardown complete for bench '$NAME'"
