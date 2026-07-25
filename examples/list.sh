#!/usr/bin/env bash
# list.sh — list benches recorded in the registry.
#
# This is a template. Adapt the configuration block below to your environment.

set -euo pipefail

BENCH_ROOT="${BENCH_ROOT:-/opt/benches}"
REGISTRY_FILE="${REGISTRY_FILE:-${BENCH_ROOT}/registry.json}"
JSON=false

while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=true; shift ;;
    --help) echo "Usage: $0 [--json]"; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ ! -f "$REGISTRY_FILE" ]; then
  echo "ERROR: registry not found: $REGISTRY_FILE" >&2
  exit 1
fi

if [ "$JSON" = true ]; then
  jq '.benches' "$REGISTRY_FILE"
else
  printf "%-24s %-20s %-12s %-10s %-12s %s\n" "NAME" "SITE" "STATUS" "WEB PORT" "BRANCH" "PURPOSE"
  jq -r '.benches[] | [.name, .site_name, .status, .ports.webserver, .branch, .purpose] | @tsv' "$REGISTRY_FILE" \
    | while IFS=$'\t' read -r name site status web branch purpose; do
        printf "%-24s %-20s %-12s %-10s %-12s %s\n" "$name" "$site" "$status" "$web" "$branch" "$purpose"
      done
fi
