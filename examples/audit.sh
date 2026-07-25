#!/usr/bin/env bash
# audit.sh — reconcile the bench registry against reality.
#
# This is a template. Adapt the configuration block below to your environment.
# Default mode is read-only. Use --fix to move orphans to quarantine.

set -euo pipefail

# ==================== CONFIGURATION ====================
BENCH_ROOT="${BENCH_ROOT:-/opt/benches}"
REFERENCE_BENCH_NAME="${REFERENCE_BENCH_NAME:-reference}"
REGISTRY_FILE="${REGISTRY_FILE:-${BENCH_ROOT}/registry.json}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-change-me}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
MARIADB_HOST="${MARIADB_HOST:-mariadb}"
REDIS_HOST="${REDIS_HOST:-redis}"
QUARANTINE_DIR="${BENCH_ROOT}/.quarantine"
DB_PREFIX="${DB_PREFIX:-bench_}"
FIX=false
JSON=false
# =======================================================

usage() {
  cat <<EOF
Usage: $0 [--json] [--fix]

Options:
  --json   Output machine-readable JSON
  --fix    Move orphaned directories to quarantine and release resources
  --help   Show this help
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --fix) FIX=true; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [ ! -f "$REGISTRY_FILE" ]; then
  echo "ERROR: registry not found: $REGISTRY_FILE" >&2
  exit 1
fi

report_ok() { [ "$JSON" = true ] || echo "OK      $1"; }
report_drift() { [ "$JSON" = true ] || echo "DRIFT   $1"; }
report_orphan() { [ "$JSON" = true ] || echo "ORPHAN  $1"; }
report_missing() { [ "$JSON" = true ] || echo "MISSING $1"; }

echo "=== Audit benches under $BENCH_ROOT ==="

# 1. Check each registry entry against reality
jq -r '.benches[] | @base64' "$REGISTRY_FILE" | while read -r row; do
  entry=$(echo "$row" | base64 --decode)
  name=$(echo "$entry" | jq -r '.name')
  path=$(echo "$entry" | jq -r '.path')
  web_port=$(echo "$entry" | jq -r '.ports.webserver')
  pid=$(echo "$entry" | jq -r '.pid // empty')
  db_name=$(echo "$entry" | jq -r '.database.db_name')
  db_user=$(echo "$entry" | jq -r '.database.db_user')
  redis_cache_db=$(echo "$entry" | jq -r '.redis.cache_db')

  # path exists?
  if [ ! -d "$path" ]; then
    report_missing "bench '$name': directory missing ($path)"
  else
    report_ok "bench '$name': directory exists"
  fi

  # pid running?
  if [ -n "$pid" ]; then
    if kill -0 "$pid" 2>/dev/null; then
      report_ok "bench '$name': process $pid running"
    else
      report_drift "bench '$name': pid $pid not running"
    fi
  fi

  # port listening?
  if command -v ss >/dev/null 2>&1; then
    if ss -tlnp 2>/dev/null | grep -q ":$web_port "; then
      report_ok "bench '$name': port $web_port listening"
    else
      report_drift "bench '$name': port $web_port not listening"
    fi
  fi

  # DB exists?
  db_exists=$(mariadb -h "$MARIADB_HOST" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" \
    -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name='$db_name';" 2>/dev/null || true)
  if [ -n "$db_exists" ]; then
    report_ok "bench '$name': database $db_name exists"
  else
    report_missing "bench '$name': database $db_name missing"
  fi

  # DB user exists?
  user_exists=$(mariadb -h "$MARIADB_HOST" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" \
    -e "SELECT User FROM mysql.user WHERE User='$db_user';" 2>/dev/null || true)
  if [ -n "$user_exists" ]; then
    report_ok "bench '$name': user $db_user exists"
  else
    report_missing "bench '$name': user $db_user missing"
  fi
done

# 2. Find orphaned directories
echo "--- Directories not in registry ---"
for dir in "$BENCH_ROOT"/*; do
  [ -d "$dir" ] || continue
  basename=$(basename "$dir")
  [ "$basename" = ".quarantine" ] && continue
  [ "$basename" = "$REFERENCE_BENCH_NAME" ] && continue
  if ! jq -e --arg name "$basename" '.benches[$name]' "$REGISTRY_FILE" >/dev/null 2>&1; then
    report_orphan "directory '$basename' not in registry"
    if [ "$FIX" = true ]; then
      mkdir -p "$QUARANTINE_DIR"
      mv "$dir" "$QUARANTINE_DIR/"
      echo "  moved to quarantine"
    fi
  fi
done

# 3. Find orphaned databases/users
echo "--- Databases/users not in registry ---"
known_dbs=$(jq -r '.benches[].database.db_name' "$REGISTRY_FILE" 2>/dev/null | sort -u)
known_users=$(jq -r '.benches[].database.db_user' "$REGISTRY_FILE" 2>/dev/null | sort -u)

actual_dbs=$(mariadb -h "$MARIADB_HOST" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" \
  -e "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE '${DB_PREFIX}%';" 2>/dev/null | tail -n +2 || true)
actual_users=$(mariadb -h "$MARIADB_HOST" -u "$DB_ROOT_USER" -p"$DB_ROOT_PASSWORD" \
  -e "SELECT User FROM mysql.user WHERE User LIKE '${DB_PREFIX}%';" 2>/dev/null | tail -n +2 || true)

for db in $actual_dbs; do
  if ! echo "$known_dbs" | grep -q "^${db}$"; then
    report_orphan "database '$db' not in registry"
  fi
done

for user in $actual_users; do
  if ! echo "$known_users" | grep -q "^${user}$"; then
    report_orphan "user '$user' not in registry"
  fi
done

# 4. Find orphaned Redis DBs
echo "--- Redis DBs with keys but no registry entry ---"
known_redis_dbs=$(jq -r '.benches[].redis | .cache_db, .queue_db, .socketio_db' "$REGISTRY_FILE" 2>/dev/null | sort -un)
for db in $(seq 0 15); do
  size=$(redis-cli -h "$REDIS_HOST" -n "$db" DBSIZE 2>/dev/null || echo 0)
  size=${size#*:}
  size=${size// /}
  if [ "${size:-0}" -gt 0 ] && ! echo "$known_redis_dbs" | grep -q "^${db}$"; then
    report_orphan "redis DB $db has $size keys but is not in registry"
  fi
done

echo "=== Audit complete ==="
