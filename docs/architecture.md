# Architecture

## Overview

The model separates **shared infrastructure** from **disposable benches**. It is designed for **agentic parallel development**: multiple AI agents or developers working on multiple PRs/features at the same time, each with a live bench for browser-level testing.

```mermaid
flowchart TB
    subgraph Host["Docker Host"]
        subgraph Shared["Shared Services"]
            MariaDB[(MariaDB Container)]
            Redis[(Redis Container)]
        end

        subgraph Benches["Benches"]
            Reference["Reference Bench<br/>(stable, never mutated)"]
        D1["Disposable Bench 1<br/>feature/x checkout"]
        D2["Disposable Bench 2<br/>feature/y checkout"]
        D3["Disposable Bench 3<br/>PR #123 checkout"]
        end

        Registry["Registry<br/>registry.json"]

        Reference --> MariaDB
        Reference --> Redis
        D1 --> MariaDB
        D1 --> Redis
        D2 --> MariaDB
        D2 --> Redis
        D3 --> MariaDB
        D3 --> Redis

        Registry -.tracks.-> Reference
        Registry -.tracks.-> D1
        Registry -.tracks.-> D2
        Registry -.tracks.-> D3
    end

    Agent1["Agent / Developer 1"] --> D1
    Agent2["Agent / Developer 2"] --> D2
    Agent3["CI Job"] --> D3
```

## Key components

### Reference bench

- Long-lived, stable, **never mutated**.
- Source of backups for restore-from-reference disposable benches.
- Protected by a hard-coded guard in every script.

### Disposable benches

- One per feature branch, track worktree, or PR.
- Full independent `bench init` with its own `apps/`, `env/`, `sites/`.
- `apps/<app>` is a normal Git checkout of the selected branch, not a symlink to
  the coding worktree.
- Short-lived; torn down after work is done.

### Track development worktrees

- One managed Git worktree per disposable bench, created under the owning track.
- This is the coding/commit path and is separate from the bench checkout.
- Teardown removes it through `git worktree remove --force` after the bench is
  stopped and its app checkout is removed.

### Shared MariaDB

- One container serves all benches.
- Each bench gets a dedicated database and database user.
- Prevents cross-bench data access by grants, not by container isolation.

### Shared Redis

- One container serves all benches.
- Each bench gets dedicated Redis DB indexes for cache, queue, and socketio.
- Never use `FLUSHALL`; always `FLUSHDB` on the specific index.

### Registry

- Single source of truth for every bench.
- Records name, path, site, ports, Redis DBs, DB user, branch, status, PID.
- Locked with `flock` during allocation to prevent races.

## Isolation boundaries

| Resource | Isolation mechanism |
|----------|---------------------|
| App code in bench | Separate normal Git branch checkout per bench |
| Development code | Track-owned Git worktree per bench |
| Python env | Separate `env/` per bench |
| Database | Separate DB name + DB user per bench |
| Redis cache | Separate Redis DB index per bench |
| Redis queue | Separate Redis DB index per bench |
| Ports | Unique published port tuple per bench |
| Processes | One `bench start` per bench, tracked by PID |

## What is NOT isolated

- **MariaDB server resources** — a runaway query affects all benches.
- **Redis server resources** — memory and CPU are shared.
- **Queue semantics** — RQ workers can still consume jobs from another bench's queue DB if misconfigured. For strong job isolation, run a dedicated queue Redis per bench.
- **Network** — all benches can reach the shared services.

## First-run flow

```mermaid
sequenceDiagram
    participant User
    participant Skill
    participant Docker
    participant Registry

    Skill->>Docker: Detect existing benches
    alt benches found
        Skill->>User: Present candidates, ask for reference bench
        User->>Skill: Confirm reference bench
        Skill->>Registry: Mark reference bench
    else no benches
        Skill->>User: No environment found
        User->>Skill: Choose bootstrap or abort
        opt bootstrap
            Skill->>Docker: Clone frappe_docker, start services
            Skill->>Registry: Mark new bench as reference
        end
    end
```

## Port and Redis allocation

Ports are allocated from configurable bases:

```text
webserver_port = WEBSERVER_BASE_PORT + n
socketio_port  = SOCKETIO_BASE_PORT + n
file_watcher   = FILE_WATCHER_BASE_PORT + n
redis_db       = n
```

`n` is the smallest non-negative integer not already reserved in the registry.
