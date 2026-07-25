# frappe-multihand

> Give your Frappe development **many hands** — one stable reference bench plus as many disposable benches as you need, all sharing one Docker MariaDB/Redis stack.

A skill for safely running **multiple Frappe/ERPNext benches** on a single Docker host with shared MariaDB and Redis services, so developers and AI agents can do parallel feature work without colliding.

## Why this exists

Frappe development often needs isolated environments: one for a feature branch, one for a bug reproduction, one for a CI job. But Frappe has hard constraints:

- Only one version of an app can be installed per bench.
- Only one `bench start` can run per bench.
- Each bench expects its own database, ports, and Redis namespaces.

Creating a completely separate Docker stack for every branch is slow and wasteful. This skill defines a pragmatic middle ground:

- One **reference bench** stays stable and is never mutated.
- Many **disposable benches** are created on demand, one per worktree/branch/PR.
- All benches share MariaDB and Redis containers, but each bench gets its own DB user, DB name, Redis DB index, and port tuple.
- A small **registry** tracks every bench so nothing is orphaned.

## Who it's for

- Frappe/ERPNext developers who want parallel local environments.
- **Teams running multiple AI coding agents on the same Frappe codebase.** This is the core use case: several agents working on several PRs/features at the same time, each needing a live bench to test against.
- CI pipelines that need disposable, reproducible benches.
- Anyone who has accidentally left orphaned benches, databases, or processes behind.

## Agentic parallel development

Modern AI coding agents don't just write code — they need to **run it**. For Frappe apps, that means a live bench with a real site, real database, and often browser-level testing. When you have multiple agents (or humans) working on multiple PRs or features in parallel, a single bench becomes the bottleneck.

frappe-multihand gives every agent its own **live, disposable bench**:

- **Agent A** works on `feature/auth-refactor` in bench `feature-auth-20250725` on port 8081.
- **Agent B** works on `fix/invoice-calc` in bench `fix-invoice-20250725` on port 8082.
- **Agent C** reproduces a production bug in bench `bug-repro-20250725` on port 8083, restored from the reference bench's latest backup.

Each agent can:

- Run `bench start` and hit the site in a browser (`http://localhost:8081`, `:8082`, `:8083`).
- Run `bench migrate`, `bench test`, or `bench console` without affecting the others.
- Use Playwright or other browser automation against its own isolated site.
- Tear the bench down cleanly when the PR is merged or the bug is fixed.

The **registry** keeps track of every bench, so agents don't fight over ports or leave orphaned databases behind. The **reference bench** stays untouched, so there's always a clean baseline to compare against or restore from.

## What you get

| File | Purpose |
|------|---------|
| `SKILL.md` | The operational skill content: provision, track, teardown, audit. |
| `docs/architecture.md` | Architecture overview and diagram. |
| `examples/docker-compose.yml` | Minimal shared-services compose file. |
| `examples/registry.json` | Sample registry showing reference + disposable benches. |
| `examples/provision.sh` | Template script to create a disposable bench. |
| `examples/teardown.sh` | Template script to remove a disposable bench. |
| `examples/audit.sh` | Template script to reconcile registry vs reality. |
| `INSTALL.md` | How to install this skill for Kimi, Claude, Codex, OpenCode, Pi, Antigravity, etc. |

## Quick start

1. **Install the skill** — see `INSTALL.md`.

2. **Detect your environment** — the skill will look for existing Frappe benches and ask you to confirm the reference bench. If none exist, it can bootstrap from the official `frappe_docker` repo.

3. **Adapt the examples** — copy `examples/` to your bench root and set the configuration points:

   ```bash
   export BENCH_ROOT=/opt/benches
   export REFERENCE_BENCH_NAME=reference
   export DB_ROOT_PASSWORD=secret
   export WEBSERVER_BASE_PORT=8080
   ```

4. **Create a disposable bench**:

   ```bash
   ./examples/provision.sh \
     --name feature-x \
     --branch feature/x \
     --app myapp \
     --from-reference
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
2. Set `REFERENCE_BENCH_NAME` to your stable bench.
3. Set `REDIS_HOST` to your Redis service name (`redis`, `redis-cache`, etc.).
4. Choose base ports and let the scripts allocate offsets.

## Safety model

- The reference bench is protected by a hard-coded guard in every script.
- Teardown never uses `FLUSHALL`; it only flushes per-bench Redis DB indexes.
- All destructive actions support `--dry-run`.
- The registry is locked during allocation to prevent races between agents.

## Contributing

Issues and improvements welcome. The skill is intentionally generic; keep it that way.
