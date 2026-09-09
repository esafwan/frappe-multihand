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
REFERENCE_SITE="${REFERENCE_SITE:-${REFERENCE_BENCH_NAME}.local}"
REGISTRY_FILE="${REGISTRY_FILE:-${BENCH_ROOT}/registry.json}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-change-me}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
MARIADB_HOST="${MARIADB_HOST:-mariadb}"
# Left unset by default (not "redis"): the per-role defaults and reference-
# bench auto-detect logic below need to distinguish "user set REDIS_HOST
# explicitly" from "nothing set it yet". Only set this yourself for
# single-Redis setups where one hostname actually resolves for every role.
REDIS_HOST="${REDIS_HOST:-}"
WEBSERVER_BASE_PORT="${WEBSERVER_BASE_PORT:-8080}"
SOCKETIO_BASE_PORT="${SOCKETIO_BASE_PORT:-9000}"
FILE_WATCHER_BASE_PORT="${FILE_WATCHER_BASE_PORT:-6787}"
APP_REPO="${APP_REPO:-}"
SOURCE_REPO="${SOURCE_REPO:-}"
APP_NAME="${APP_NAME:-}"
FRAPPE_BRANCH="${FRAPPE_BRANCH:-version-15}"
FRAMEWORK_SEED="${FRAMEWORK_SEED:-}"
FRAMEWORK_SEED_ID="${FRAMEWORK_SEED_ID:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
SIGNED_BY="${SIGNED_BY:-${USER:-unknown}}"
DRY_RUN=false
# Default to restoring from the reference bench's latest backup, not a blank
# site — the whole point of maintaining a reference bench is that new benches
# start with real data. Pass --blank to opt out when an empty site is what's
# actually wanted (e.g. testing a fresh-install / onboarding flow).
FROM_REFERENCE=true
# =======================================================

# Parse redis://host:port[/db] and emit "host:port". Defaults to the value of
# REDIS_HOST (or "redis") on port 6379 when the URL is missing or malformed.
parse_redis_url() {
  local url="$1"
  local host="${REDIS_HOST:-redis}" port="6379"
  if [[ "$url" =~ ^redis://([^:/]+)(:([0-9]+))?(/[0-9]+)?$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]:-6379}"
  fi
  echo "${host}:${port}"
}

# Default per-role Redis hostnames. Many devcontainer compose setups do not
# publish a plain "redis" service — only role-specific services like
# "redis-cache" and "redis-queue" resolve via DNS (socketio traffic is
# typically routed through the queue instance). If REDIS_HOST is set
# explicitly, it overrides all three roles uniformly (single-Redis setups).
# If a reference bench exists and REDIS_HOST was not explicitly overridden,
# its Redis service names/ports below take precedence over these defaults.
# Each disposable bench still gets its own DB index for isolation.
REDIS_CACHE_HOST="${REDIS_HOST:-redis-cache}"
REDIS_QUEUE_HOST="${REDIS_HOST:-redis-queue}"
REDIS_SOCKETIO_HOST="${REDIS_HOST:-redis-queue}"
REDIS_CACHE_PORT=6379
REDIS_QUEUE_PORT=6379
REDIS_SOCKETIO_PORT=6379
if [ -z "${REDIS_HOST:-}" ] && [ -f "${REFERENCE_BENCH_DIR}/sites/common_site_config.json" ]; then
  REF_REDIS_CACHE=$(jq -r '.redis_cache // empty' "${REFERENCE_BENCH_DIR}/sites/common_site_config.json")
  REF_REDIS_QUEUE=$(jq -r '.redis_queue // empty' "${REFERENCE_BENCH_DIR}/sites/common_site_config.json")
  REF_REDIS_SOCKETIO=$(jq -r '.redis_socketio // empty' "${REFERENCE_BENCH_DIR}/sites/common_site_config.json")
  # Only override a role's default when the reference config actually has
  # that key. A missing/malformed key must not clobber the good per-role
  # default above with parse_redis_url's own generic ("redis") fallback.
  [ -n "$REF_REDIS_CACHE" ] && REDIS_CACHE_HOST=$(parse_redis_url "$REF_REDIS_CACHE" | cut -d: -f1) && REDIS_CACHE_PORT=$(parse_redis_url "$REF_REDIS_CACHE" | cut -d: -f2)
  [ -n "$REF_REDIS_QUEUE" ] && REDIS_QUEUE_HOST=$(parse_redis_url "$REF_REDIS_QUEUE" | cut -d: -f1) && REDIS_QUEUE_PORT=$(parse_redis_url "$REF_REDIS_QUEUE" | cut -d: -f2)
  [ -n "$REF_REDIS_SOCKETIO" ] && REDIS_SOCKETIO_HOST=$(parse_redis_url "$REF_REDIS_SOCKETIO" | cut -d: -f1) && REDIS_SOCKETIO_PORT=$(parse_redis_url "$REF_REDIS_SOCKETIO" | cut -d: -f2)
fi

usage() {
  cat <<'EOF'
Usage: $0 --name <bench-name> --branch <branch> --track-dir <track-dir> [options]

Options:
  --name <name>        Bench name (required). Prefer 'mh new <name> ...',
                        which accepts the name positionally and forwards it
                        here as --name.
  --branch <branch>    Git branch to checkout (required)
  --track-dir <path>   Owning track directory (required)
  --source-repo <path-or-url>
                        Local Git repository, or a remote Git URL (https://,
                        git://, ssh://, or user@host:path). A URL is
                        equivalent to setting APP_REPO and omitting this
                        flag: a shared bare clone is kept under
                        BENCH_ROOT/.sources and re-fetched on every run so
                        newly pushed branches are visible.
  --worktree <path>    Worktree output path; must be inside --track-dir
  --app <app-name>     Frappe app name (default: APP_NAME env var). This is
                        the "primary" app under test: it gets a track-owned
                        development worktree (§3.1) and is what --branch
                        applies to. Exactly one per bench.
  --extra-app <name>@<branch>[@<source>]
                        A pinned dependency app, repeatable (e.g. erpnext,
                        hrms). Cloned straight into bench/apps/ via
                        `bench get-app` — no development worktree, since
                        these aren't the app under test. <source> is
                        optional; when omitted, `bench get-app` resolves the
                        bare app name against the frappe/erpnext GitHub orgs
                        (fails for apps hosted elsewhere, e.g. `huf` needs an
                        explicit source URL). Installed before --app, in the
                        order given, since the primary app commonly depends
                        on them (e.g. ury needs erpnext+hrms already
                        installed). `mh new --workspace <name>` expands a
                        workspace manifest into a series of these flags —
                        prefer that over hand-writing --extra-app directly.
  --run-after-install <command>
                        A shell command to run (via `bash -c`, cwd =
                        $BENCH_DIR) after all apps are installed, repeatable,
                        in the order given. For deterministic per-app setup
                        steps a manifest can declare (e.g. `cd apps/ury &&
                        yarn install` for a yarn-workspaces monorepo app) —
                        see workspaces.json's post_install_commands.
  --framework-seed <bench-path>
                        Create this bench with `bench init --clone-from` using
                        a verified, immutable framework seed. The seed is
                        copied; it is never modified or mounted. Its
                        dependency app revisions must match this bench's
                        declared app matrix.
  --framework-seed-id <id>
                        Immutable identity/fingerprint of --framework-seed.
                        Recorded in registry.json and BENCH_IDENTITY.md.
  --from-reference     Restore data from reference bench's latest backup
                        (this is the DEFAULT — this flag is a no-op kept for
                        explicitness/back-compat; use --blank to opt out)
  --blank               Provision an empty site instead of restoring from the
                        reference bench. Use for testing a fresh-install /
                        onboarding flow where starting data would be noise.
  --reference-backup-dir <dir>
                        Use an explicit backup directory instead of the
                        reference bench's own sites/<site>/private/backups/.
                        Must contain a matching set of files named
                        <ts>-<site>-database.sql.gz, <ts>-<site>-files.tgz,
                        and <ts>-<site>-private-files.tgz (the standard
                        `bench backup --with-files` output). Implies
                        --from-reference (the default).
  --dry-run            Print actions without executing
  --help               Show this help

Environment variables that usually need an explicit override in this
environment (defaults will fail otherwise):
  DB_ROOT_PASSWORD   MariaDB root password. Default "change-me" is a
                     placeholder; find the real value with:
                       docker inspect -f '{{range .Config.Env}}{{if eq (index (split . "=") 0) "MYSQL_ROOT_PASSWORD"}}{{index (split . "=") 1}}{{end}}{{end}}' <mariadb-container>
  REDIS_HOST         Redis service hostname for ALL roles (cache/queue/
                     socketio). Only set this for single-Redis setups where
                     "redis" (or your chosen name) actually resolves. Left
                     unset, cache defaults to "redis-cache" and
                     queue/socketio default to "redis-queue" — the service
                     names used by this project's devcontainer.
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

# Append $1 (an app name) to $BENCH_DIR/sites/apps.txt, idempotently and
# newline-safely. `bench init` does not guarantee apps.txt ends in a
# newline, and neither does `bench get-app` reliably update it for every app
# — appending without checking corrupts it into a single concatenated line
# (e.g. "frappehuf"), which breaks every subsequent bench command with
# ModuleNotFoundError. Call this after any app clone/get-app, not just the
# primary app — this was previously only done for the primary app, which is
# exactly the gap that made `bench get-app huf` + `install-app huf` fail with
# "App huf not in apps.txt" on a real run.
register_app_in_apps_txt() {
  local app_name="$1"
  local apps_txt="${BENCH_DIR}/sites/apps.txt"
  if [ -s "$apps_txt" ] && [ -n "$(tail -c1 "$apps_txt")" ]; then
    printf '\n' >> "$apps_txt"
  fi
  if ! grep -qxF "$app_name" "$apps_txt" 2>/dev/null; then
    printf '%s\n' "$app_name" >> "$apps_txt"
  fi
}

# Parse args
NAME=""
BRANCH=""
TRACK_DIR="${TRACK_DIR:-}"
WORKTREE=""
APP=""
REFERENCE_BACKUP_DIR=""
EXTRA_APPS=()
POST_INSTALL_CMDS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    --track-dir) TRACK_DIR="$2"; shift 2 ;;
    --source-repo) SOURCE_REPO="$2"; shift 2 ;;
    --worktree) WORKTREE="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --extra-app) EXTRA_APPS+=("$2"); shift 2 ;;
    --run-after-install) POST_INSTALL_CMDS+=("$2"); shift 2 ;;
    --framework-seed) FRAMEWORK_SEED="$2"; shift 2 ;;
    --framework-seed-id) FRAMEWORK_SEED_ID="$2"; shift 2 ;;
    --from-reference) FROM_REFERENCE=true; shift ;;
    --blank) FROM_REFERENCE=false; shift ;;
    --reference-backup-dir) REFERENCE_BACKUP_DIR="$2"; FROM_REFERENCE=true; shift 2 ;;
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

if [ -n "$FRAMEWORK_SEED" ]; then
  if [ ! -d "$FRAMEWORK_SEED" ] || [ ! -d "$FRAMEWORK_SEED/apps/frappe" ]; then
    echo "ERROR: --framework-seed must be an existing Bench with apps/frappe: $FRAMEWORK_SEED" >&2
    exit 1
  fi
  FRAMEWORK_SEED=$(abs_existing_dir "$FRAMEWORK_SEED")
  [ -n "$FRAMEWORK_SEED_ID" ] || FRAMEWORK_SEED_ID="$(git -C "$FRAMEWORK_SEED/apps/frappe" rev-parse HEAD 2>/dev/null || echo unknown)"
fi

require_command git
require_command jq

# Guard against clobbering ANY persistent bench, not just the one named by
# REFERENCE_BENCH_NAME. With multiple named reference benches (one per
# workspace, see workspaces.json / `mh reference`), a run whose caller forgot
# to export the matching REFERENCE_BENCH_NAME would otherwise sail right past
# a name-only check and provision over a different persistent bench. The
# registry is the actual source of truth for "is this bench persistent" —
# check it first, and keep the env-var check as a second, cheaper guard for
# the common case (works even before the registry file exists).
if [ "$NAME" = "$REFERENCE_BENCH_NAME" ]; then
  echo "ERROR: refusing to provision over reference bench '$REFERENCE_BENCH_NAME'" >&2
  exit 1
fi
if [ -f "$REGISTRY_FILE" ]; then
  existing_type=$(jq -r --arg name "$NAME" '.benches[$name].type // empty' "$REGISTRY_FILE" 2>/dev/null || true)
  if [ "$existing_type" = "persistent" ]; then
    echo "ERROR: refusing to provision over persistent bench '$NAME' (registry.json .benches.\"$NAME\".type == \"persistent\")" >&2
    exit 1
  fi
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

# --source-repo accepts either a local filesystem path or a remote Git URL
# (https://, git://, ssh://, or scp-like user@host:path). A URL passed here
# is equivalent to setting APP_REPO and omitting --source-repo.
looks_like_git_url() {
  case "$1" in
    *://*) return 0 ;;
    *@*:*) return 0 ;;
    *) return 1 ;;
  esac
}
if [ -n "$SOURCE_REPO" ] && [ ! -d "$SOURCE_REPO" ] && looks_like_git_url "$SOURCE_REPO"; then
  APP_REPO="$SOURCE_REPO"
  SOURCE_REPO=""
fi

# Resolve or create a private source repository. A local source checkout is
# only used as the worktree source; it is never mounted into the bench.
# A remote APP_REPO is mirrored once into a shared bare clone under
# BENCH_ROOT/.sources and reused/fetched on every subsequent provision, so a
# branch pushed after the first provisioning run is still visible.
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
    else
      # Fetch into refs/remotes/origin/*, never directly into refs/heads/*:
      # other disposable benches may have this shared bare clone's branches
      # checked out live in their own worktrees, and Git refuses to fetch
      # into a ref that is checked out elsewhere. The branch-resolution step
      # below already falls back to refs/remotes/origin/$BRANCH (creating a
      # fresh local branch) when refs/heads/$BRANCH doesn't exist yet, so a
      # branch pushed after the clone was created is still picked up.
      log "Refreshing shared source clone: $SOURCE_REPO"
      dry git -C "$SOURCE_REPO" fetch origin '+refs/heads/*:refs/remotes/origin/*' --prune
    fi
  else
    echo "ERROR: --source-repo (local path or Git URL) or APP_REPO is required" >&2
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

log "Provisioning bench '$NAME' (branch: $BRANCH, app: $APP, data: $([ "$FROM_REFERENCE" = true ] && echo "from-reference" || echo "blank"))"
log "  track: $TRACK_DIR"
log "  worktree: $WORKTREE"
log "  source: $SOURCE_REPO"
[ -n "$FRAMEWORK_SEED" ] && log "  framework seed: $FRAMEWORK_SEED ($FRAMEWORK_SEED_ID)"

if [ "$DRY_RUN" = false ]; then
  if jq -e --arg name "$NAME" '.benches[$name]' "$REGISTRY_FILE" >/dev/null 2>&1; then
    existing_worktree=$(jq -r --arg name "$NAME" '.benches[$name].worktree // empty' "$REGISTRY_FILE")
    [ "$existing_worktree" = "$WORKTREE" ] || {
      flock -u 200
      echo "ERROR: bench '$NAME' already exists with a different worktree" >&2
      exit 1
    }
    # A resumed provision must use the resource allocation recorded in its
    # provisioning intent. Recomputing the DB password, Redis DB indexes, or
    # ports here would desynchronize the registry from the MariaDB user,
    # Redis config, and site config already created by the earlier attempt.
    existing_db_password=$(jq -r --arg name "$NAME" '.benches[$name].database.db_password // empty' "$REGISTRY_FILE")
    [ -n "$existing_db_password" ] && DB_PASSWORD="$existing_db_password"
    existing_cache_db=$(jq -r --arg name "$NAME" '.benches[$name].redis.cache_db // empty' "$REGISTRY_FILE")
    existing_queue_db=$(jq -r --arg name "$NAME" '.benches[$name].redis.queue_db // empty' "$REGISTRY_FILE")
    existing_socketio_db=$(jq -r --arg name "$NAME" '.benches[$name].redis.socketio_db // empty' "$REGISTRY_FILE")
    [ -n "$existing_cache_db" ] && REDIS_CACHE_DB="$existing_cache_db"
    [ -n "$existing_queue_db" ] && REDIS_QUEUE_DB="$existing_queue_db"
    [ -n "$existing_socketio_db" ] && REDIS_SOCKETIO_DB="$existing_socketio_db"
    existing_web_port=$(jq -r --arg name "$NAME" '.benches[$name].ports.webserver // empty' "$REGISTRY_FILE")
    existing_socketio_port=$(jq -r --arg name "$NAME" '.benches[$name].ports.socketio // empty' "$REGISTRY_FILE")
    existing_watcher_port=$(jq -r --arg name "$NAME" '.benches[$name].ports.file_watcher // empty' "$REGISTRY_FILE")
    [ -n "$existing_web_port" ] && WEB_PORT="$existing_web_port"
    [ -n "$existing_socketio_port" ] && SOCK_PORT="$existing_socketio_port"
    [ -n "$existing_watcher_port" ] && WATCH_PORT="$existing_watcher_port"
    log "Resuming existing provisioning intent for '$NAME'"
  else
    # Build the apps[] array: the primary app (role "primary") plus every
    # --extra-app entry (role "dependency") — see the workspaces.json model
    # in SKILL.md §3.2/§4.4a. app_name/bench_app_checkout stay pointed at the
    # primary for backward compatibility with anything reading those two
    # fields directly; apps[] is the full picture.
    EXTRA_APPS_JSON="[]"
    for entry in "${EXTRA_APPS[@]+"${EXTRA_APPS[@]}"}"; do
      IFS='@' read -r extra_name extra_branch extra_source <<< "$entry"
      EXTRA_APPS_JSON=$(jq -c --argjson acc "$EXTRA_APPS_JSON" \
        --arg n "$extra_name" --arg b "$extra_branch" --arg s "${extra_source:-}" \
        '$acc + [{name: $n, role: "dependency", branch: $b, source: (if $s == "" then null else $s end)}]' <<< '{}')
    done
    TMP=$(mktemp)
    jq --arg name "$NAME" \
       --arg path "$BENCH_DIR" \
       --arg site "$SITE_NAME" \
       --arg branch "$BRANCH" \
       --arg worktree "$WORKTREE" \
       --arg track "$TRACK_DIR" \
       --arg source "$SOURCE_REPO" \
       --arg app "$APP" \
       --arg seed "$FRAMEWORK_SEED" \
       --arg seed_id "$FRAMEWORK_SEED_ID" \
       --argjson extra_apps "$EXTRA_APPS_JSON" \
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
          framework_seed: (if $seed == "" then null else {path: $seed, id: $seed_id} end),
          apps: ([{name: $app, role: "primary", branch: $branch, source: $source}] + $extra_apps),
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

log "  ports: web=$WEB_PORT socketio=$SOCK_PORT watcher=$WATCH_PORT"
log "  redis: cache=${REDIS_CACHE_HOST}:${REDIS_CACHE_PORT}/${REDIS_CACHE_DB} queue=${REDIS_QUEUE_HOST}:${REDIS_QUEUE_PORT}/${REDIS_QUEUE_DB} socketio=${REDIS_SOCKETIO_HOST}:${REDIS_SOCKETIO_PORT}/${REDIS_SOCKETIO_DB}"
log "  db: $DB_NAME / $DB_USER"

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
  if [ -n "$FRAMEWORK_SEED" ]; then
    # Bench's clone-from path copies repositories into a new bench directory.
    # It does not share mutable files with the seed. Keep a fresh-framework
    # fallback for diagnostics and incompatible app matrices.
    dry bench init --clone-from "$FRAMEWORK_SEED" "$BENCH_DIR"
  else
    dry bench init --frappe-branch "$FRAPPE_BRANCH" "$BENCH_DIR"
  fi
fi

# All bench subcommands below (pip install, set-config, new-site, ...) must
# run with cwd inside the bench root, or `bench` cannot locate env/bin/python
# and fails with "No virtual environment ... found for path env/bin/python".
if [ "$DRY_RUN" = false ]; then
  cd "$BENCH_DIR"
fi

# `bench init` seeds Procfile with its own default web port, independent of
# the registry-assigned $WEB_PORT set via `bench set-config` below — the two
# are separate files and set-config alone does not touch Procfile. Left
# unfixed, the bench serves on the wrong port and whichever bench starts
# second on that stale port silently steals it from another bench. It also
# seeds `redis_cache:`/`redis_queue:` process entries that spawn LOCAL Redis
# on fixed ports (6381/6383 by default), which collides with any other
# bench's local Redis on the same host and crashes the whole `honcho`
# process group on `bench start`. This skill's model is always shared
# Redis containers (§3.3) — the site is already pointed at
# ${REDIS_CACHE_HOST}/${REDIS_QUEUE_HOST} above — so these local-Redis
# Procfile entries are never wanted here; strip them. Both fixes are
# idempotent (safe to re-run on an existing bench).
if [ "$DRY_RUN" = false ] && [ -f "$BENCH_DIR/Procfile" ]; then
  sed -i.bak -E "/^web:/ s/--port [0-9]+/--port ${WEB_PORT}/" "$BENCH_DIR/Procfile"
  sed -i.bak -E '/^redis_cache:/d; /^redis_queue:/d' "$BENCH_DIR/Procfile"
  rm -f "$BENCH_DIR/Procfile.bak"
fi

mkdir -p "$BENCH_DIR/apps"
APP_PATH="$BENCH_DIR/apps/$APP"
if [ -e "$APP_PATH" ] || [ -L "$APP_PATH" ]; then
  [ ! -L "$APP_PATH" ] || {
    echo "ERROR: bench app path must be a normal Git checkout, not a symlink: $APP_PATH" >&2
    exit 1
  }
  if [ -n "$FRAMEWORK_SEED" ]; then
    # A seed contains its own baseline primary checkout. Materialize the
    # requested branch in this copied checkout so runtime code remains
    # independent from both the seed and the track worktree.
    dry git -C "$APP_PATH" fetch --no-tags "$SOURCE_REPO" "$BRANCH"
    dry git -C "$APP_PATH" checkout -B "$BRANCH" FETCH_HEAD
  else
    current_branch=$(git -C "$APP_PATH" branch --show-current 2>/dev/null || true)
    [ "$current_branch" = "$BRANCH" ] || {
      echo "ERROR: bench app checkout is on '$current_branch', expected '$BRANCH': $APP_PATH" >&2
      exit 1
    }
  fi
else
  dry git clone --branch "$BRANCH" --single-branch "$SOURCE_REPO" "$APP_PATH"

  if [ "$DRY_RUN" = false ]; then
    register_app_in_apps_txt "$APP"
  fi
fi

# Install the app's Python package unconditionally: idempotent, and required
# on every retry, not just a truly fresh clone. A prior partial/failed run
# can leave apps/$APP present without ever having pip-installed it, which
# then silently skips this step forever (ModuleNotFoundError at runtime).
dry bench pip install -e "$APP_PATH"

# Fetch and register pinned dependency apps (--extra-app), before the
# primary app is installed on the site below — the primary commonly depends
# on these (e.g. ury needs erpnext+hrms already present). Each entry is
# "<name>@<branch>[@<source>]"; get-app handles the org-shorthand vs.
# explicit-URL resolution and its own clone+pip-install, so this just adds
# the apps.txt registration get-app doesn't reliably do on its own (the exact
# gap that broke a real `huf` install: "App huf not in apps.txt" after a
# successful `bench get-app huf <url>`).
for entry in "${EXTRA_APPS[@]+"${EXTRA_APPS[@]}"}"; do
  IFS='@' read -r extra_name extra_branch extra_source <<< "$entry"
  if [ -z "$extra_name" ] || [ -z "$extra_branch" ]; then
    echo "ERROR: malformed --extra-app entry (expected name@branch[@source]): $entry" >&2
    exit 1
  fi
  EXTRA_APP_PATH="$BENCH_DIR/apps/$extra_name"
  if [ -d "$EXTRA_APP_PATH" ]; then
    log "Extra app '$extra_name' already present; reusing (idempotent)"
  else
    log "Fetching extra app: $extra_name@$extra_branch${extra_source:+ from $extra_source}"
    if [ "$DRY_RUN" = true ]; then
      log "would run: bench get-app $extra_name --branch $extra_branch ${extra_source:-}"
    else
      dry bench get-app "$extra_name" --branch "$extra_branch" ${extra_source:+"$extra_source"}
    fi
  fi
  [ "$DRY_RUN" = false ] && register_app_in_apps_txt "$extra_name"
done

# Configure
dry bench set-config -g db_host "$MARIADB_HOST"
dry bench set-config -g db_port 3306
dry bench set-config -g redis_cache "redis://${REDIS_CACHE_HOST}:${REDIS_CACHE_PORT}/${REDIS_CACHE_DB}"
dry bench set-config -g redis_queue "redis://${REDIS_QUEUE_HOST}:${REDIS_QUEUE_PORT}/${REDIS_QUEUE_DB}"
dry bench set-config -g redis_socketio "redis://${REDIS_SOCKETIO_HOST}:${REDIS_SOCKETIO_PORT}/${REDIS_SOCKETIO_DB}"
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
    --db-password "$DB_PASSWORD" \
    --force
fi

if [ "$FROM_REFERENCE" = true ]; then
  # Locate a matching set of `bench backup --with-files` output files, either
  # from an explicit --reference-backup-dir or the reference bench's own
  # sites/<site>/private/backups/ (most recent by filename timestamp prefix).
  BACKUP_SEARCH_DIR="${REFERENCE_BACKUP_DIR:-${REFERENCE_BENCH_DIR}/sites/${REFERENCE_SITE}/private/backups}"
  if [ ! -d "$BACKUP_SEARCH_DIR" ]; then
    echo "ERROR: --from-reference requested but backup directory does not exist: ${BACKUP_SEARCH_DIR}" >&2
    exit 1
  fi

  SQL_FILE=$(find "$BACKUP_SEARCH_DIR" -maxdepth 1 -name '*-database.sql.gz' | sort | tail -1)
  if [ -z "$SQL_FILE" ]; then
    echo "ERROR: no *-database.sql.gz backup found in ${BACKUP_SEARCH_DIR}" >&2
    exit 1
  fi
  # Public/private files backups share the SQL file's timestamp+site prefix
  # (strip the known suffix rather than globbing independently, so a stale
  # unrelated archive in the same directory can't get paired with the wrong
  # SQL). Frappe emits these as .tgz (compress_backup) or plain .tar
  # (uncompressed) depending on site config — a manually-provided backup dir
  # (e.g. Telegram/Slack-shared) and a bench's own `bench backup --with-files`
  # output have been observed to differ here, so check both extensions.
  BACKUP_PREFIX="${SQL_FILE%-database.sql.gz}"
  PUBLIC_FILES=""
  for ext in tgz tar; do
    [ -f "${BACKUP_PREFIX}-files.${ext}" ] && PUBLIC_FILES="${BACKUP_PREFIX}-files.${ext}" && break
  done
  PRIVATE_FILES=""
  for ext in tgz tar; do
    [ -f "${BACKUP_PREFIX}-private-files.${ext}" ] && PRIVATE_FILES="${BACKUP_PREFIX}-private-files.${ext}" && break
  done

  RESTORE_ARGS=(--force restore "$SQL_FILE" --mariadb-root-username "$DB_ROOT_USER" --mariadb-root-password "$DB_ROOT_PASSWORD")
  [ -n "$PUBLIC_FILES" ] && RESTORE_ARGS+=(--with-public-files "$PUBLIC_FILES") || log "WARN: no matching public files backup (${BACKUP_PREFIX}-files.{tgz,tar}); restoring database only"
  [ -n "$PRIVATE_FILES" ] && RESTORE_ARGS+=(--with-private-files "$PRIVATE_FILES") || log "WARN: no matching private files backup (${BACKUP_PREFIX}-private-files.{tgz,tar}); restoring database only"

  log "Restoring from reference backup: ${SQL_FILE}"
  dry bench --site "$SITE_NAME" "${RESTORE_ARGS[@]}"

  # §4.5.3: copy the reference bench's encryption_key so encrypted fields in
  # the restored data (passwords, integration secrets) stay decryptable.
  # Never pass --encryption-key on the same restore command as
  # --with-public-files/--with-private-files (bench rejects that combination);
  # setting it after restore is the only supported order.
  REF_SITE_CONFIG="${REFERENCE_BENCH_DIR}/sites/${REFERENCE_SITE}/site_config.json"
  if [ "$DRY_RUN" = false ] && [ -f "$REF_SITE_CONFIG" ]; then
    REF_KEY=$(jq -r '.encryption_key // empty' "$REF_SITE_CONFIG")
    if [ -n "$REF_KEY" ]; then
      dry bench --site "$SITE_NAME" set-config encryption_key "$REF_KEY"
    else
      log "WARN: reference site_config.json has no encryption_key; restored site keeps its own freshly-generated key, so any encrypted values from the backup will fail to decrypt"
    fi
  fi

  # Reconcile schema differences between the backup's source app versions and
  # this bench's cloned app versions.
  dry bench --site "$SITE_NAME" migrate
fi

# Install dependency apps first (primary commonly depends on them), then the
# primary app from the bench's branch checkout — never from the development
# worktree, never with a shared source path. Both idempotent — a no-op for
# any app the restore above already installed.
for entry in "${EXTRA_APPS[@]+"${EXTRA_APPS[@]}"}"; do
  IFS='@' read -r extra_name _ _ <<< "$entry"
  dry bench --site "$SITE_NAME" install-app "$extra_name"
done
dry bench --site "$SITE_NAME" install-app "$APP"

# Run any declared post-install setup commands (e.g. `cd apps/ury && yarn
# install` for a yarn-workspaces monorepo app) — deterministic per-app setup
# steps a workspace manifest can automate, as opposed to free-text notes an
# agent has to remember by hand. Runs with cwd = $BENCH_DIR; each command is
# logged before running so a failure is traceable to which one broke.
for cmd in "${POST_INSTALL_CMDS[@]+"${POST_INSTALL_CMDS[@]}"}"; do
  log "Running post-install command: $cmd"
  if [ "$DRY_RUN" = true ]; then
    log "would run: $cmd"
  else
    (cd "$BENCH_DIR" && bash -c "$cmd")
  fi
done

log "Health check: run 'bench start' and curl http://127.0.0.1:${WEB_PORT}/api/method/ping"

if [ "$DRY_RUN" = false ]; then
  exec 200>"$LOCK_FILE"
  flock -x 200
  TMP=$(mktemp)
  jq --arg name "$NAME" '.benches[$name].status = "ready"' "$REGISTRY_FILE" > "$TMP"
  mv "$TMP" "$REGISTRY_FILE"
  flock -u 200

  cat > "$BENCH_DIR/BENCH_IDENTITY.md" <<EOF
# STOP — read before modifying

This is a disposable bench provisioned by frappe-multihand.

| Field | Value |
| --- | --- |
| Bench | $NAME |
| Branch | $BRANCH |
| Framework seed | ${FRAMEWORK_SEED:-fresh-framework} |
| Seed identity | ${FRAMEWORK_SEED_ID:-n/a} |
| Registry | $REGISTRY_FILE |
| Site | $SITE_NAME |

The seed is a source template only. This bench owns its writable site, database,
Redis namespaces, ports, and app checkout. Use `mh audit` before recovery or
`mh teardown $NAME` only after the owner has finished with the bench.
EOF
fi

trap - ERR
log "Provision complete for bench '$NAME'"
