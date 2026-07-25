---
name: frappe-multihand
description: >
  Safely create, run, track, and tear down disposable Frappe benches inside a
  Docker devcontainer with shared MariaDB/Redis services, so multiple agents or
  developers can do parallel feature work on the same app without colliding.
  General-purpose; not tied to a specific machine, site, app, or repository.
license: MIT
compatibility: "Kimi Code, Claude Code, Cursor, OpenCode, Codex, Pi, Antigravity."
metadata:
  author: swarm
  version: "2.0"
---

# frappe-multihand

**Trigger phrases:**

- "create a disposable frappe bench"
- "parallel frappe testing"
- "clean up orphaned frappe benches"
- "frappe multihand"
- "multi-hand frappe docker"
- "spawn a new frappe bench for this branch"
- "frappe bench per worktree"
- "temporary frappe bench in docker"
- "isolate frappe bench mariadb redis"
- "/mh-new"
- "/mh-list"
- "/mh-testplan"
- "/mh-teardown"
- "/mh-audit"
- "mh new"
- "mh list"
- "mh testplan"
- "mh teardown"
- "mh audit"

---

## 1. When to use this skill

Use this skill when you need more than one Frappe/ERPNext bench on a single Docker host that already runs shared MariaDB and Redis containers (e.g. a devcontainer, CI runner, or local development server).

### Core use case: agentic parallel development

The primary audience is **teams running multiple AI coding agents on the same Frappe codebase**. Each agent works on a different PR, feature, or bugfix in parallel and needs its own **live bench** for browser-level testing, `bench start`, `bench migrate`, `bench console`, and `bench test`.

Typical reasons:

- **Agent A** tests `feature/auth-refactor` on port 8081 while **Agent B** tests `fix/invoice-calc` on port 8082 — both with live sites, real databases, and browser automation.
- Run parallel CI jobs that each need a full bench with real `bench start`.
- Reproduce a bug against a copy of production data while development continues elsewhere.
- Keep a stable reference bench untouched as a baseline for comparisons and backups.

Do **not** use this for production multi-tenancy. Disposable benches are intentionally short-lived and co-located; the isolation model is pragmatic, not hardened.

---

## 2. First-run detection and reference-bench selection

Before doing anything else, the skill must determine whether a bench environment already exists and, if so, which bench is the **reference bench**.

### 2.1 Detect an existing environment

Look for the following signals (in order):

1. Running Docker containers whose names or images suggest Frappe/bench, MariaDB, or Redis:

   ```bash
   docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' \
     | grep -iE 'frappe|bench|mariadb|redis'
   ```

2. Docker Compose files in likely locations (project root, `.devcontainer/`, `docker/`, `development/`):

   ```bash
   find . -maxdepth 3 \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) 2>/dev/null
   ```

3. Existing bench directories on disk (common layouts):

   ```bash
   # common patterns: ./frappe-bench, ./development/<name>, ./benches/<name>
   find . -maxdepth 3 -type d \( -name 'frappe-bench' -o -name 'development' -o -name 'benches' \) 2>/dev/null
   ```

4. Any existing registry file (`registry.json` / `registry.yaml`) in the bench root.

### 2.2 Confirm with the user

If benches are found, present them to the user and ask which is the reference bench. Example:

> I found the following benches:
> - `frappe-bench` (sites: `site-a.local`, `site-b.local`)
> - `development/16` (sites: `main.local`)
>
> Which should be the reference bench (never mutated, source of truth for backups)?

Only after explicit confirmation should the skill mark a bench as the reference bench in the registry.

### 2.3 No environment found

If no bench environment is detected, do **not** silently create one. Options:

1. **Bootstrap from the official Frappe Docker repo** (if the user wants):

   ```bash
   git clone https://github.com/frappe/frappe_docker.git
   cd frappe_docker
   cp example.env .env
   docker compose -f docker-compose.yml -f overrides/compose.redis.yaml up -d
   ```

   Then run `bench init` inside the container. Explain that this creates the shared MariaDB/Redis services the skill expects.

2. **Stop and ask for the environment** if bootstrapping is out of scope for the current session.

Never assume a reference bench exists without confirmation.

---

## 3. Core model

### 3.1 One bench per disposable worktree/branch

Each disposable bench is a full, independent `bench init`. It owns:

- its own `apps/` directory (a copy or worktree of the app under test),
- its own Python `env/`,
- its own `sites/`,
- its own allocated ports.

The bench lives in a dedicated directory under a **bench root**, e.g. `${BENCH_ROOT}/<bench-name>/`.

### 3.2 Reference bench

Maintain one **reference bench** that is always stable and never mutated. It is the source of truth for:

- a known-good site backup (`bench backup --with-files`),
- reference app versions,
- reference site config values.

Name it unmistakably (e.g. `reference`, `main`, `stable`). Every teardown and provisioning script must refuse to operate on the reference bench.

### 3.3 Shared services

MariaDB and Redis run as sibling containers, **not** inside the bench container:

```yaml
# docker-compose.services.yml (illustrative)
services:
  mariadb:
    image: mariadb:10.6
    env_file: .env
    ports:
      - "3306:3306"
    volumes:
      - mariadb_data:/var/lib/mysql

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
```

One Redis instance is usually enough. Point `redis_cache`, `redis_queue`, and `redis_socketio` at it, but give each bench a distinct **Redis DB index** for each of the three roles. If you need stronger queue isolation, run a second Redis container named `redis-queue` and keep `redis_cache`/`redis_socketio` on the first.

### 3.4 Config split

| File | Scope | What goes there | How to set |
|------|-------|-----------------|------------|
| `sites/common_site_config.json` | bench-wide | DB host, Redis hosts/ports, `webserver_port`, `socketio_port`, `file_watcher_port`, `developer_mode`, etc. | `bench set-config -g <key> <value>` |
| `sites/<site>/site_config.json` | per-site | `db_name`, `db_password`, `encryption_key`, per-site feature flags | `bench --site <site> set-config <key> <value>` |

Example common-site wiring against the shared containers:

```bash
bench set-config -g db_host mariadb
bench set-config -g db_port 3306
bench set-config -g redis_cache "redis://redis:6379/${REDIS_CACHE_DB}"
bench set-config -g redis_queue "redis://redis:6379/${REDIS_QUEUE_DB}"
bench set-config -g redis_socketio "redis://redis:6379/${REDIS_SOCKETIO_DB}"
bench set-config -g webserver_port 8081
bench set-config -g socketio_port 9001
bench set-config -g file_watcher_port 6788
bench set-config -g developer_mode 1
bench set-config -g serve_default_site true
bench set-config -g default_site "${SITE_NAME}"
```

Replace `REDIS_CACHE_DB`, `REDIS_QUEUE_DB`, `REDIS_SOCKETIO_DB` with per-bench Redis DB indexes. The service name `redis` above is illustrative; match the actual service name in your compose file (common alternatives are `redis-cache`, `redis-queue`, `redis-socketio`, or a single `redis`).

Per-site config example:

```bash
bench --site ${SITE_NAME} set-config db_name "${DB_NAME}"
bench --site ${SITE_NAME} set-config db_password "${DB_PASSWORD}"
bench --site ${SITE_NAME} set-config encryption_key "${ENCRYPTION_KEY}"
```

---

## 4. Provisioning

### 4.1 Pre-provision checklist

Before creating resources, verify:

1. Bench name is not the reference-bench name.
2. The intended `(webserver_port, socketio_port, file_watcher_port)` tuple is not already reserved in the registry or in use on the host.
3. Redis DB indexes for cache/queue/socketio are not already reserved in the registry.
4. The registry lock file is free.

### 4.2 Atomic registry write (concurrency safety)

Use a filesystem lock so multiple agents provisioning simultaneously do not race on port/Redis allocation. Example:

```bash
LOCK_FILE="${BENCH_ROOT}/.registry.lock"
exec 200>"${LOCK_FILE}"
flock -x 200
# read registry, allocate ports & DB indexes, write intent record
flock -u 200
```

The registry record is written **before** any real resources are created. It marks the bench as `provisioning`. If the script later fails, the partial record is still present and can be used for cleanup or retry.

### 4.3 Registry intent record

A minimal registry entry (JSON or YAML) must contain:

```json
{
  "name": "feature-x-20250725",
  "path": "${BENCH_ROOT}/feature-x-20250725",
  "site_name": "feature-x.local",
  "branch": "feature/x",
  "worktree": "${APP_WORKTREE_ROOT}/feature-x",
  "purpose": "Test feature/x before PR",
  "ports": {
    "webserver": 8081,
    "socketio": 9001,
    "file_watcher": 6788
  },
  "redis": {
    "cache_db": 1,
    "queue_db": 2,
    "socketio_db": 3
  },
  "database": {
    "db_name": "feature_x_20250725",
    "db_user": "feature_x_20250725",
    "db_password": "<generated>"
  },
  "status": "provisioning",
  "created_at": "2025-07-25T14:30:00Z",
  "created_by": "agent-or-developer-id"
}
```

Store the registry in one place, e.g. `${BENCH_ROOT}/registry.json` or `${BENCH_ROOT}/registry.yaml`. Every create/teardown/audit command must go through it.

### 4.4 Fresh empty site mode

Steps for a brand-new empty site:

```bash
# 1. Allocate resources and write provisioning intent (locked).
# 2. Create bench directory.
bench init --frappe-branch version-15 \
  --apps_path "${BENCH_DIR}/apps" \
  "${BENCH_DIR}"

cd "${BENCH_DIR}"

# 3. Get the app(s) under test (or use a local worktree path).
bench get-app "${APP_REPO}" --branch "${BRANCH}"

# 4. Set common-site config (ports, Redis, DB host).
bench set-config -g db_host mariadb
bench set-config -g db_port 3306
bench set-config -g redis_cache "redis://redis:6379/${REDIS_CACHE_DB}"
bench set-config -g redis_queue "redis://redis:6379/${REDIS_QUEUE_DB}"
bench set-config -g redis_socketio "redis://redis:6379/${REDIS_SOCKETIO_DB}"
bench set-config -g webserver_port "${WEBSERVER_PORT}"
bench set-config -g socketio_port "${SOCKETIO_PORT}"
bench set-config -g file_watcher_port "${FILE_WATCHER_PORT}"
bench set-config -g developer_mode 1

# 5. Create MariaDB user and database.
# Use `mariadb` (or `mysql` on older images) as the client command.
mariadb -h mariadb -u root -p"${DB_ROOT_PASSWORD}" <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'%' IDENTIFIED BY '${DB_PASSWORD}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'%';
FLUSH PRIVILEGES;
SQL

# 6. Create site.
bench new-site "${SITE_NAME}" \
  --mariadb-root-username root \
  --mariadb-root-password "${DB_ROOT_PASSWORD}" \
  --admin-password "${ADMIN_PASSWORD}" \
  --db-name "${DB_NAME}" \
  --db-password "${DB_PASSWORD}"

# 7. Install app(s).
bench --site "${SITE_NAME}" install-app "${APP_NAME}"

# 8. Mark registry status "ready" and run health check.
```

### 4.5 Restore-from-reference mode

Use this when you need realistic data from the reference bench.

#### 4.5.1 Create the backup in the reference bench first

From the reference bench directory, run:

```bash
bench --site "${REFERENCE_SITE}" backup --with-files
```

This produces SQL + public/private file archives in `sites/${REFERENCE_SITE}/private/backups/`.

#### 4.5.2 Provision an empty bench, then restore

Provision the bench exactly as in the fresh mode up to the `new-site` step, but **stop before installing apps**. Then restore:

```bash
bench --site "${SITE_NAME}" \
  --force restore "${BACKUP_SQL_FILE}" \
  --with-public-files "${PUBLIC_FILES_TAR}" \
  --with-private-files "${PRIVATE_FILES_TAR}"
```

#### 4.5.3 Encryption-key gotcha (critical)

After restore, copy the reference site's `encryption_key` into the new site's `site_config.json`. Without this, encrypted fields, passwords, and secrets will fail at runtime.

```bash
# Read the key from the reference site's config file to avoid bench CLI differences.
# REFERENCE_BENCH_DIR is the path to the reference bench (e.g. ${BENCH_ROOT}/reference).
REFERENCE_KEY=$(grep -o '"encryption_key": *"[^"]*"' \
  "${REFERENCE_BENCH_DIR}/sites/${REFERENCE_SITE}/site_config.json" \
  | head -1 | cut -d'"' -f4)
bench --site "${SITE_NAME}" set-config encryption_key "${REFERENCE_KEY}"
```

**Never** pass `--encryption-key` on the same `bench restore` command as `--with-public-files` or `--with-private-files`. Frappe rejects that combination; it is a known CLI limitation. Always restore first, then set the key.

After setting the encryption key, reinstall the app if needed:

```bash
bench --site "${SITE_NAME}" install-app "${APP_NAME}"
```

If the backup already contains the app installed, you may skip reinstallation, but verify with `bench --site ${SITE_NAME} list-apps`.

### 4.6 Health check

After `bench start` is running, do not mark the bench ready until the site responds with HTTP 200:

```bash
bench start &
BENCH_PID=$!

for i in {1..60}; do
  if curl -fsS "http://127.0.0.1:${WEBSERVER_PORT}/api/method/ping" >/dev/null 2>&1; then
    echo "READY"
    break
  fi
  sleep 1
done

# If the loop expires, capture logs and roll back.
```

Save the `BENCH_PID` in the registry (or the process group ID) so teardown can stop the bench.

### 4.7 Port and Redis index allocation strategy

Define a configurable range, for example:

| Bench | webserver_port | socketio_port | file_watcher_port | redis_cache_db | redis_queue_db | redis_socketio_db |
|-------|----------------|---------------|-------------------|----------------|----------------|-------------------|
| reference | 8080 | 9000 | 6787 | 0 | 0 | 0 |
| disposable-1 | 8081 | 9001 | 6788 | 1 | 1 | 1 |
| disposable-2 | 8082 | 9002 | 6789 | 2 | 2 | 2 |

Indexes 0–15 are available in a default Redis build. If you expect more than 15 disposable benches concurrently, run a separate Redis instance or namespace keys with prefixes; do not rely solely on DB indexes.

Allocation algorithm:

1. Load the registry.
2. Find the smallest integer `n` such that port tuple `(base_web + n, base_socket + n, base_watcher + n)` is unused and `n` is not a reserved Redis DB.
3. Reserve it atomically under the lock.
4. Verify on the host that the ports are not already listening (`ss -tlnp` / `lsof -i`) before using them.

---

## 5. Registry and reconciliation

### 5.1 Registry location and format

Keep a single source of truth, for example `${BENCH_ROOT}/registry.json`. Each entry is one bench. Required fields:

- `name`
- `path`
- `site_name`
- `status` (`provisioning`, `ready`, `stopping`, `stopped`, `failed`, `orphaned`)
- `ports` (webserver, socketio, file_watcher)
- `redis` (cache_db, queue_db, socketio_db)
- `database` (db_name, db_user)
- `branch`, `worktree`, `purpose`
- `created_at`, `created_by`
- `pid` or `process_group` of `bench start` if running

### 5.2 Audit / reconcile command

An `audit` or `reconcile` command must cross-check the registry against reality and flag drift:

```bash
# For each registry entry:
#   - Does ${path} exist?
#   - Is ${pid} a running process?
#   - Are the configured ports actually listening?
#   - Does the MariaDB user exist?
#   - Does the MariaDB database exist?
#   - Are Redis DB indexes still empty of unexpected keys?
#
# For each file in ${BENCH_ROOT}/ not in registry:
#   - Flag as orphaned directory.
#
# For each MariaDB user/db matching the project prefix but not in registry:
#   - Flag as orphaned database/user.
#
# For each listening port in the configured range not in registry:
#   - Flag as orphaned listener.
```

Report categories:

- `OK`: registry matches reality.
- `DRIFT`: registry and reality differ (e.g. port listening but no process recorded).
- `ORPHAN`: resource exists without registry entry.
- `MISSING`: registry entry points to a resource that no longer exists.

### 5.3 Repair actions from audit

The audit command should be read-only by default. With `--fix` or `--prune` it may:

- Move orphaned bench directories to a quarantine path for manual review.
- Drop orphaned DBs/users after a confirmation prompt.
- Release orphaned Redis DB indexes back to the pool.
- Update registry status fields to match reality.

---

## 6. Teardown and cleanup

### 6.1 Idempotent teardown

Teardown must be safely re-runnable. Steps (in order):

```bash
# 1. Lock registry; set status to "stopping".
# 2. Stop bench process (if pid recorded).
if [ -n "${PID}" ] && kill -0 "${PID}" 2>/dev/null; then
  kill -TERM "${PID}"
  sleep 5
  kill -KILL "${PID}" 2>/dev/null || true
fi

# 3. Drop MariaDB database.
mariadb -h mariadb -u root -p"${DB_ROOT_PASSWORD}" \
  -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;"

# 4. Drop MariaDB user.
mariadb -h mariadb -u root -p"${DB_ROOT_PASSWORD}" \
  -e "DROP USER IF EXISTS '${DB_USER}'@'%'; FLUSH PRIVILEGES;"

# 5. Clear this bench's Redis DB indexes (NOT flushall).
for db in "${REDIS_CACHE_DB}" "${REDIS_QUEUE_DB}" "${REDIS_SOCKETIO_DB}"; do
  redis-cli -h redis -n "${db}" FLUSHDB
done

# 6. Remove bench directory.
rm -rf "${BENCH_DIR}"

# 7. Remove registry entry (or mark "stopped" if you keep history).
# 8. Unlock registry.
```

### 6.2 Partial-provision rollback

If provisioning fails after the registry intent record is written, teardown must still succeed:

- `DROP DATABASE IF EXISTS` and `DROP USER IF EXISTS` are idempotent.
- `FLUSHDB` on a non-existent Redis DB is harmless.
- `rm -rf` of a partially created bench is safe.
- Port/Redis allocations are released from the registry only after cleanup.

Therefore the same teardown script can be invoked both for normal teardown and for rollback. Mark the registry status `failed` during rollback so audit can report it.

### 6.3 Reference bench guard

Every teardown command must immediately exit if the target matches the reference bench name. Hard-code the guard:

```bash
if [ "${BENCH_NAME}" == "${REFERENCE_BENCH_NAME}" ]; then
  echo "REFUSING to teardown the reference bench: ${BENCH_NAME}" >&2
  exit 1
fi
```

---

## 7. Orphan detection

### 7.1 Orphaned directories

Any directory under `${BENCH_ROOT}/` that is not present in the registry is an orphan. Do not delete automatically; move to `${BENCH_ROOT}/.quarantine/` and flag in audit.

### 7.2 Orphaned MariaDB resources

List all DBs/users created by this project by convention (e.g. prefix `bench_`):

```sql
SELECT User FROM mysql.user WHERE User LIKE 'bench_%';
SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'bench_%';
```

Any DB/user not matching a current registry entry is an orphan.

### 7.3 Orphaned processes

Scan for bench processes that are not recorded in the registry:

```bash
ps aux | grep -E 'bench start|frappe|gunicorn|redis' | grep -v grep
ss -tlnp | awk '{print $4}' | grep -E ':808[0-9]|:900[0-9]|:678[0-9]'
```

### 7.4 Orphaned Redis keys

List keys per DB index to detect benches that left data behind:

```bash
for db in {0..15}; do
  echo "DB ${db}:"
  redis-cli -h redis -n "${db}" INFO keyspace
  redis-cli -h redis -n "${db}" DBSIZE
done
```

If a DB index has keys but no registry entry uses that index, it is orphaned.

---

## 8. Safety rules and gotchas

### 8.1 Absolute guards

1. **Never teardown the reference bench.** Hard-code and test the guard.
2. **Never mutate the reference bench's database or Redis keys.** Read-only backups only.
3. **Never run `redis-cli flushall`.** Always use `FLUSHDB` on the specific DB index.
4. **Never reuse a Redis DB index** that is already allocated to another bench.
5. **Never reuse a port tuple** without verifying it is free.

### 8.2 Shared-queue risk

Using the same Redis instance with DB indexes for `redis_queue` does **not** fully isolate job queues. RQ workers from one bench can in principle consume jobs from another bench's queue DB if misconfigured. Worse, schedulers across benches may interact. This is a data-corruption risk.

Mitigations:

- Use a dedicated Redis instance for queues if benches run workers/scheduler.
- Or run workers only in the reference/stable bench and use disposable benches for web/API testing only.
- If disposable benches must run workers, clear their queue DB immediately after teardown.

### 8.3 Port publishing

Allocated ports must be published by the bench container at runtime. If using Docker Compose, map them explicitly:

```yaml
ports:
  - "${WEBSERVER_PORT}:${WEBSERVER_PORT}"
  - "${SOCKETIO_PORT}:${SOCKETIO_PORT}"
  - "${FILE_WATCHER_PORT}:${FILE_WATCHER_PORT}"
```

Without publishing, health checks and external agents cannot reach the bench.

### 8.4 Encryption key on restore

See section 4.5.3. If you forget to copy `encryption_key`, the site may appear to work but will fail whenever it decrypts stored secrets. Symptoms include:

- OAuth/Integration settings failing with decryption errors,
- Password fields returning garbage,
- background jobs raising `EncryptionError`.

Always set the encryption key immediately after restore.

### 8.5 Concurrency and locking

All registry writes, port allocations, and teardowns must take the same filesystem lock. A race between two provisioning agents can cause duplicate port/DB allocation and cross-bench corruption.

### 8.6 Idempotency verification

A provision script should:

- Skip `bench init` if the directory already exists and contains a valid bench.
- Skip `new-site` if the site already exists in `sites/`.
- Skip DB/user creation if they already exist.
- Skip app install if the app is already installed on the site.

A teardown script should:

- Ignore already-stopped processes.
- Use `DROP ... IF EXISTS` for DB/user.
- Use `FLUSHDB`, not `FLUSHALL`.

---

## 9. Companion scripts

The `examples/` directory contains template scripts you can adapt:

- `provision.sh` — create a disposable bench (supports `--from-reference`, `--dry-run`).
- `teardown.sh` — remove a disposable bench and release resources.
- `list.sh` — list registered benches.
- `audit.sh` — reconcile registry vs reality, with optional `--fix`.
- `cleanup-orphans.sh` — convenience wrapper around `audit.sh --fix`.
- `docker-compose.yml` — minimal shared-services compose file.
- `registry.json` — sample registry with one reference and one disposable bench.

Every destructive script should support `--dry-run` (or `--plan`) that prints what it would do without doing it.

Configuration points you must set before using the templates:

| Variable | Example | Meaning |
|----------|---------|---------|
| `BENCH_ROOT` | `/opt/benches` | Parent directory for all benches |
| `REFERENCE_BENCH_NAME` | `reference` | Name of the protected reference bench |
| `REFERENCE_BENCH_DIR` | `${BENCH_ROOT}/${REFERENCE_BENCH_NAME}` | Path to reference bench |
| `REFERENCE_SITE` | `main.local` | Primary site in the reference bench |
| `DB_ROOT_PASSWORD` | `secret` | MariaDB root password |
| `WEBSERVER_BASE_PORT` | `8080` | Base for disposable webserver ports |
| `SOCKETIO_BASE_PORT` | `9000` | Base for disposable socketio ports |
| `FILE_WATCHER_BASE_PORT` | `6787` | Base for disposable file-watcher ports |
| `REDIS_HOST` | `redis` | Shared Redis service hostname |
| `APP_REPO` | `git@github.com:org/app.git` | App repository URL |
| `APP_NAME` | `myapp` | Frappe app name |

---

## 9a. Helper CLI (`mh`)

The `examples/mh` script is a thin wrapper that provides quick commands for humans and agents. It is intended to be copied into your bench root or added to `PATH`.

### Commands

| Command | What it does |
|---------|--------------|
| `mh new <name> --branch <branch> [--app <app>] [--from-reference] [--dry-run]` | Create a disposable bench (wraps `provision.sh`). |
| `mh list [--json]` | List registered benches (wraps `list.sh`). |
| `mh testplan <name> [--output <file>]` | Generate a test plan template for a bench. |
| `mh open <name>` | Open the bench site in the default browser. |
| `mh logs <name>` | Tail the bench logs. |
| `mh teardown <name> [--dry-run]` | Remove a disposable bench (wraps `teardown.sh`). |
| `mh audit [--fix] [--json]` | Reconcile registry vs reality (wraps `audit.sh`). |
| `mh status` | Quick status of benches (ports, processes). |
| `mh doctor` | Check environment prerequisites. |

### Slash-command style triggers for agents

When a user types one of the following, treat it as an instruction to run the corresponding `mh` command (or the underlying script if `mh` is not installed):

| Trigger | Action |
|---------|--------|
| `/mh-new <name> --branch <branch>` | `mh new <name> --branch <branch>` |
| `/mh-list` | `mh list` |
| `/mh-testplan <name>` | `mh testplan <name>` |
| `/mh-open <name>` | `mh open <name>` |
| `/mh-teardown <name>` | `mh teardown <name>` |
| `/mh-audit` | `mh audit` |
| `/mh-status` | `mh status` |
| `/mh-doctor` | `mh doctor` |

If `mh` is not on `PATH`, fall back to running the underlying `examples/*.sh` scripts directly with the same arguments.

---

## 10. Costs and reuse strategies

`bench init` plus `bench get-app` is slow (minutes) and disk-heavy (gigabytes per bench) because each bench gets its own Frappe framework copy and Python environment.

Alternatives to reduce cost:

- **Frozen framework copy:** maintain a pre-built Frappe framework image or volume. Clone it per bench instead of running `bench init` from scratch.
- **App-only worktrees:** keep the framework directory shared/read-only and use Git worktrees only for the app under test. This deviates from the "full independent bench" model but is viable if you accept shared framework code.
- **Persistent disposable bench pool:** keep a warm pool of pre-initialized benches. An agent checks out a ready bench, renames/configures it, and returns it to a teardown queue.
- **Bind-mount app source:** instead of copying `apps/myapp`, mount the worktree directory into the bench container. Avoids duplication but requires the app to tolerate being run from a mounted path.

Even with optimizations, each disposable bench should still have its own `sites/`, `env/`, ports, DB user, and Redis DB index.

---

## 11. Limitations of the shared-container model

- **Redis DB indexes are limited to 16 by default.** Plan accordingly or run additional Redis instances.
- **Shared queue Redis is not fully isolated.** Running workers/scheduler in multiple disposable benches can cause cross-bench job execution. Prefer web-only disposable benches or dedicated queue Redis instances.
- **MariaDB is shared.** A runaway query or large restore affects all benches. Set per-user resource limits if needed.
- **Single host.** This model is not a distributed/multi-node deployment.
- **Not a security boundary.** A disposable bench can still reach the shared services; isolation is by convention and naming, not network policy.

---

## 12. Quick reference: safe command checklist

| Task | Safe command | Unsafe alternative |
|------|--------------|--------------------|
| Stop one bench's cache | `redis-cli -h redis -n ${DB} FLUSHDB` | `redis-cli FLUSHALL` |
| Drop a bench DB | `DROP DATABASE IF EXISTS \`${DB_NAME}\`;` | dropping `*` or the reference DB |
| Create DB user | `CREATE USER ... IDENTIFIED BY ...; GRANT ALL ON \`${DB_NAME}\`.*` | `GRANT ALL ON *.*` |
| Restore with files | restore first, then `set-config encryption_key` | `--encryption-key` + `--with-public-files` |
| Allocate resources | locked registry read + write | unguarded read-modify-write |
| Teardown | check bench name != reference first | deleting reference bench |
| Health check | `curl http://127.0.0.1:${PORT}/api/method/ping` | assuming ready after `bench start` |

---

## 13. Summary

Use one disposable `bench init` per branch/worktree, with a protected reference bench for reference data. Share MariaDB and Redis containers across benches, but isolate each bench by:

- unique MariaDB user + database,
- unique Redis DB indexes (or instances),
- unique published port tuple,
- a machine-readable, locked registry,
- idempotent provision/teardown scripts with `--dry-run` support.

Audit regularly. Never `FLUSHALL`. Never touch the reference bench. Always copy the encryption key after restore.
