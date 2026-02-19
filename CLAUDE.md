# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

Ralph Loop (`copilot_ralf`) is an autonomous AI coding loop that uses GitHub Copilot CLI (`copilot_yolo` from [copilot_here](https://github.com/GordonBeeming/copilot_here)) to iteratively complete tasks from a Markdown PRD. It uses a smart model (default: claude-sonnet-4.5) for planning and a cheap model (default: gpt-4.1) for execution.

## Prerequisites

- `copilot_here` installed (provides `copilot_yolo` shell function via `~/.copilot_here.sh`)
- GitHub CLI (`gh`) authenticated with `copilot` scope
- Docker/OrbStack/Podman running (copilot_yolo runs in Docker)

## Running

```bash
# Full pipeline: plan + review + execute
./ralph.sh "Build a REST API with authentication"

# Plan only (generates .ralph/prd.md)
./ralph-plan.sh "Build a REST API"

# Execute from existing PRD
./ralph-loop.sh

# Skip review, fully autonomous
./ralph.sh --skip-review "quick task"

# Two-phase execution (separate task selection + implementation)
./ralph.sh --two-phase "large project"
```

There are no tests, linting, or build steps for this project itself — it is a collection of bash scripts.

## Architecture

Four bash scripts with a clear separation of concerns:

- **`ralph.sh`** — Entry point. Parses CLI args, runs pre-flight checks, orchestrates plan then loop phases. Exports config as env vars for sub-scripts.
- **`ralph-plan.sh`** — Sends a user prompt to a smart model via `copilot_yolo` to generate a structured PRD at `.ralph/prd.md`. The PRD is a Markdown checklist with `- [ ]` tasks containing description, files, and acceptance criteria.
- **`ralph-loop.sh`** — Core loop. Each iteration: counts pending tasks, builds a prompt (static rules + dynamic context), executes via `copilot_yolo`, then evaluates the result using layered verification (promise string, PRD checkbox, git diff, timeout). Handles stagnation with adaptive recovery (different-approach hint → task skip → model escalation → circuit breaker).
- **`ralph-lib.sh`** — Shared library sourced by all scripts. Contains: color constants, print helpers, `.ralph/` directory management, git helpers (`snapshot_git_state`, `safe_commit`, `safe_revert`), PRD parsing (`count_pending`, `count_done`, `detect_completed_task`, `validate_prd`), progress logging, failed task tracking, pre-flight checks, and `copilot_yolo` wrappers with PTY allocation and timeout support.

## Key Design Patterns

**Layered verification**: Task completion is verified by multiple independent signals — agent promise string `<ralph>TASK_DONE</ralph>`, PRD checkbox `- [x]`, and git diff. The decision matrix in `ralph-loop.sh:424-535` maps signal combinations to verdicts (verified/partial/suspicious/no-progress).

**Fresh context per iteration**: Each loop iteration starts clean. State persists only through files (`.ralph/prd.md`, `.ralph/progress.md`, `.ralph/failed-tasks.txt`). The prompt is split into a cached static portion (rules + AGENTS.md) and a dynamic portion (iteration number, stagnation hints, error context, progress summary).

**Safe git operations**: `safe_commit` stages all files then unstages sensitive patterns (`.env*`, `*.pem`, `*.key`, etc.). `safe_revert` uses `git stash` instead of destructive operations.

**copilot_yolo wrappers** (`ralph-lib.sh`): `run_copilot_yolo` handles PTY allocation via `script` when no TTY is available. `run_copilot_yolo_with_timeout` implements a portable timeout using background processes and a watchdog (macOS lacks GNU `timeout`).

## State Files

All loop state lives in `.ralph/` within the project directory:
- `prd.md` — The task list (version controlled, human-editable)
- `progress.md` — Iteration log (gitignored)
- `failed-tasks.txt` — Pipe-delimited failure records (gitignored)
- `config.env` — Config snapshot from planning phase (gitignored)

## Shell Conventions

- All scripts use `set -eo pipefail` (fail on errors, fail on pipe errors)
- `set -u` (nounset) is intentionally NOT used because `copilot_here.sh` uses unbound variables
- PRD task format: `- [ ] **Task Title** [effort: low/medium/high]` with indented Description/Files/Acceptance fields
- Blocked tasks use `- [~]` checkbox syntax
