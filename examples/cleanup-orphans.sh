#!/usr/bin/env bash
# cleanup-orphans.sh — convenience wrapper around audit.sh --fix.
#
# This is a template. Adapt the configuration block below to your environment.

set -euo pipefail

BENCH_ROOT="${BENCH_ROOT:-/opt/benches}"
AUDIT_SCRIPT="${AUDIT_SCRIPT:-$(dirname "$0")/audit.sh}"

usage() {
  cat <<EOF
Usage: $0 [--dirs] [--db] [--redis] [--dry-run] [--force]

Options:
  --dirs    Quarantine orphaned directories
  --db      Drop orphaned databases/users (requires --force)
  --redis   Flush orphaned Redis DBs (requires --force)
  --dry-run Print actions without executing
  --force   Required for destructive --db/--redis actions
  --help    Show this help
EOF
}

DRY_RUN=false
FORCE=false
DO_DIRS=false
DO_DB=false
DO_REDIS=false

while [ $# -gt 0 ]; do
  case "$1" in
    --dirs) DO_DIRS=true; shift ;;
    --db) DO_DB=true; shift ;;
    --redis) DO_REDIS=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if [ "$DO_DB" = true ] || [ "$DO_REDIS" = true ]; then
  if [ "$FORCE" != true ]; then
    echo "ERROR: --db and --redis require --force" >&2
    exit 1
  fi
fi

echo "This is a template wrapper. The real logic lives in audit.sh --fix."
echo "Recommended: implement --db/--redis cleanup by extending audit.sh."
echo "Running audit.sh --fix --json for review..."

"$AUDIT_SCRIPT" --fix --json
