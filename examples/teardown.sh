#!/usr/bin/env bash
# teardown.sh — remove a disposable Frappe bench and release its resources.
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
REDIS_HOST="${REDIS_HOST:-redis}"
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

SITE_NAME=$(echo "$ENTRY" | jq -r '.site_name')
DB_NAME=$(echo "$ENTRY" | jq -r '.database.db_name')
DB_USER=$(echo "$ENTRY" | jq -r '.database.db_user')
REDIS_CACHE_DB=$(echo "$ENTRY" | jq -r '.redis.cache_db')
REDIS_QUEUE_DB=$(echo "$ENTRY" | jq -r '.redis.queue_db')
REDIS_SOCKETIO_DB=$(echo "$ENTRY" | jq -r '.redis.socketio_db')
PID=$(echo "$ENTRY" | jq -r '.pid // empty')

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
  mariadb -h "$MARIADB_HOST" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" \
    -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`; DROP USER IF EXISTS '${DB_USER}'@'%'; FLUSH PRIVILEGES;"
else
  echo "[DRY-RUN] would drop database $DB_NAME and user $DB_USER"
fi

# Flush Redis DBs
if [ "$DRY_RUN" = false ]; then
  for db in "$REDIS_CACHE_DB" "$REDIS_QUEUE_DB" "$REDIS_SOCKETIO_DB"; do
    redis-cli -h "$REDIS_HOST" -n "$db" FLUSHDB
  done
else
  echo "[DRY-RUN] would flush redis DBs $REDIS_CACHE_DB $REDIS_QUEUE_DB $REDIS_SOCKETIO_DB"
fi

# Remove bench directory
if [ -d "$BENCH_DIR" ]; then
  if [ "$DRY_RUN" = false ]; then
    rm -rf "$BENCH_DIR"
  else
    echo "[DRY-RUN] would remove directory $BENCH_DIR"
  fi
fi

# Remove registry entry
exec 200>"$LOCK_FILE"
flock -x 200
if [ "$DRY_RUN" = false ]; then
  TMP=$(mktemp)
  jq --arg name "$NAME" 'del(.benches[$name])' "$REGISTRY_FILE" > "$TMP"
  mv "$TMP" "$REGISTRY_FILE"
else
  echo "[DRY-RUN] would remove registry entry for $NAME"
fi
flock -u 200

log "Teardown complete for bench '$NAME'"
