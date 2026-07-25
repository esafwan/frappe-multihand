# frappe-multihand

A skill for safely running **multiple Frappe/ERPNext benches** on a single Docker host with shared MariaDB and Redis services, so developers and AI agents can do parallel feature work without colliding. Think of it as giving your Frappe setup **many hands** — one stable golden bench plus as many disposable benches as you need.

## Why this exists

Frappe development often needs isolated environments: one for a feature branch, one for a bug reproduction, one for a CI job. But Frappe has hard constraints:

- Only one version of an app can be installed per bench.
- Only one `bench start` can run per bench.
- Each bench expects its own database, ports, and Redis namespaces.

Creating a completely separate Docker stack for every branch is slow and wasteful. This skill defines a pragmatic middle ground:

- One **golden bench** stays stable and is never mutated.
- Many **disposable benches** are created on demand, one per worktree/branch/PR.
- All benches share MariaDB and Redis containers, but each bench gets its own DB user, DB name, Redis DB index, and port tuple.
- A small **registry** tracks every bench so nothing is orphaned.

## Who it's for

- Frappe/ERPNext developers who want parallel local environments.
- Teams running multiple AI coding agents on the same Frappe codebase.
- CI pipelines that need disposable, reproducible benches.
- Anyone who has accidentally left orphaned benches, databases, or processes behind.

## What you get

| File | Purpose |
|------|---------|
| `SKILL.md` | The operational skill content: provision, track, teardown, audit. |
| `docs/architecture.md` | Architecture overview and diagram. |
| `examples/docker-compose.yml` | Minimal shared-services compose file. |
| `examples/registry.json` | Sample registry showing golden + disposable benches. |
| `examples/provision.sh` | Template script to create a disposable bench. |
| `examples/teardown.sh` | Template script to remove a disposable bench. |
| `examples/audit.sh` | Template script to reconcile registry vs reality. |
| `INSTALL.md` | How to install this skill for Kimi, Claude, Codex, OpenCode, Pi, Antigravity, etc. |

## Quick start

1. **Install the skill** — see `INSTALL.md`.

2. **Detect your environment** — the skill will look for existing Frappe benches and ask you to confirm the golden bench. If none exist, it can bootstrap from the official `frappe_docker` repo.

3. **Adapt the examples** — copy `examples/` to your bench root and set the configuration points:

   ```bash
   export BENCH_ROOT=/opt/benches
   export GOLDEN_BENCH_NAME=golden
   export DB_ROOT_PASSWORD=secret
   export WEBSERVER_BASE_PORT=8080
   ```

4. **Create a disposable bench**:

   ```bash
   ./examples/provision.sh \
     --name feature-x \
     --branch feature/x \
     --app myapp \
     --from-golden
   ```

5. **Work on it**, then clean up:

   ```bash
   ./examples/teardown.sh --name feature-x
   ```

6. **Audit regularly** to catch orphans:

   ```bash
   ./examples/audit.sh --fix
   ```

## Adapting to your own Docker setup

The skill assumes:

- MariaDB and Redis run as sibling containers (not inside the bench container).
- You have a directory that serves as the **bench root** (where all benches live).
- Your Docker setup publishes a range of ports for benches.

To adapt:

1. Point `BENCH_ROOT` at your bench directory.
2. Set `GOLDEN_BENCH_NAME` to your stable bench.
3. Set `REDIS_HOST` to your Redis service name (`redis`, `redis-cache`, etc.).
4. Choose base ports and let the scripts allocate offsets.

## Safety model

- The golden bench is protected by a hard-coded guard in every script.
- Teardown never uses `FLUSHALL`; it only flushes per-bench Redis DB indexes.
- All destructive actions support `--dry-run`.
- The registry is locked during allocation to prevent races between agents.

## Contributing

Issues and improvements welcome. The skill is intentionally generic; keep it that way.
