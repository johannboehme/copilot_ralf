# copilot_ralf — Ralph Loop for GitHub Copilot CLI

Autonomous AI coding loop powered by [copilot_here](https://github.com/GordonBeeming/copilot_here).

Uses a **smart model** to plan and a **cheap model** to execute — iteratively completing tasks from a human-readable Markdown PRD.

## How It Works

```
 Rough Prompt
      │
      ▼
┌─────────────┐    Smart Model (claude-sonnet-4.5)
│ ralph-plan  │───────────────────────────────────► .ralph/prd.md
└─────────────┘
      │
      ▼  (human review)
┌─────────────┐    Cheap Model (gpt-4.1)
│ ralph-loop  │◄──────────────────────────────────► iterate
└──────┬──────┘
       │  for each task:
       │  1. Read .ralph/prd.md + progress + AGENTS.md
       │  2. Check failed-tasks list (skip known failures)
       │  3. Implement the next task
       │  4. Run tests/lint/typecheck (backpressure)
       │  5. Agent marks task [x] in prd.md
       │  6. Agent outputs <ralph>TASK_DONE</ralph>
       │  7. Loop verifies: promise + PRD mark + file changes
       │  8. Safe git commit (respects hooks, filters secrets)
       │  9. Repeat (adaptive recovery if stagnant)
       ▼
   All tasks ✓
```

## Quick Start

### Prerequisites

- [copilot_here](https://github.com/GordonBeeming/copilot_here) installed
- GitHub CLI (`gh`) authenticated with `copilot` scope
- Docker/OrbStack/Podman running

### Usage

```bash
# Clone this repo
git clone https://github.com/johannboehme/copilot_ralf.git
cd copilot_ralf
chmod +x *.sh

# One-command: plan + review + execute
./ralph.sh "Build a REST API with user authentication using Express"

# Or step by step:
./ralph-plan.sh "Build a REST API with user auth"   # generates .ralph/prd.md
# ... review and edit .ralph/prd.md ...
./ralph-loop.sh                                       # executes the loop
```

### Options

```bash
# Use different models
./ralph.sh --plan-model gpt-5 --loop-model gpt-4.1 "my prompt"

# Fully autonomous (skip review)
./ralph.sh --skip-review "quick script to sort CSV files"

# Plan only (review before executing)
./ralph.sh --plan-only "complex multi-service architecture"

# Continue from existing PRD
./ralph.sh --loop-only

# Two-phase execution (separate task selection + implementation)
./ralph.sh --two-phase "large project with many tasks"

# Custom project directory
./ralph.sh -p ./my-project "add caching layer"
```

## File Structure

| File | Purpose |
|---|---|
| `ralph.sh` | Main entry point — plan + execute |
| `ralph-plan.sh` | Generates PRD from a rough prompt |
| `ralph-loop.sh` | Iterates over PRD tasks |
| `ralph-lib.sh` | Shared library (helpers, git safety, logging) |
| `.ralph/prd.md` | Task list (generated, human-editable) |
| `.ralph/progress.md` | Iteration log with error context |
| `.ralph/failed-tasks.txt` | Tracks failed tasks to avoid retrying |
| `.ralph/config.env` | Config snapshot from planning phase |
| `AGENTS.md` | Project-specific agent instructions |
| `AGENTS.md.template` | Template for AGENTS.md |

## Configuration

All configuration via environment variables or CLI flags:

| Variable | Default | Description |
|---|---|---|
| `RALPH_PLAN_MODEL` | `claude-sonnet-4.5` | Model for task planning |
| `RALPH_LOOP_MODEL` | `gpt-4.1` | Model for task execution |
| `RALPH_PROJECT_DIR` | `.` | Project directory |
| `RALPH_MAX_ITERATIONS` | `50` | Max loop iterations |
| `RALPH_MAX_STAGNANT` | `3` | Stagnation circuit breaker threshold |
| `RALPH_TASK_TIMEOUT` | `900` | Seconds per task before timeout |
| `RALPH_AUTO_COMMIT` | `true` | Git commit after each task |
| `RALPH_SKIP_HOOKS` | `false` | Skip git pre-commit hooks |
| `RALPH_TWO_PHASE` | `false` | Two-phase task execution |

## Verification Strategy

The loop uses **layered verification** instead of naive file-change detection:

| Layer | Signal | Source | What it proves |
|---|---|---|---|
| 1 | Promise string `<ralph>TASK_DONE</ralph>` | Agent output | Agent believes task is done |
| 2 | Tests/lint/build pass | Agent runs them | Code quality gates pass |
| 3 | PRD checkbox `- [x]` | Agent edits prd.md | Agent marked specific task done |
| 4 | File changes (git diff) | Loop detects | Something was actually modified |
| 5 | Adaptive stagnation recovery | Loop escalates | Recovers before circuit break |
| 6 | Execution timeout | Loop enforces | Prevents infinite hangs |

**Decision matrix:**

| Promise | PRD marked | Files changed | Verdict |
|---|---|---|---|
| DONE | [x] | yes | **VERIFIED** — commit and continue |
| - | [x] | yes | **COMPLETED** — trust PRD mark |
| DONE | - | yes | **PARTIAL** — accept, next iter marks PRD |
| DONE | - | no | **SUSPICIOUS** — retry, mark as failed |
| - | - | yes | **INCOMPLETE** — agent crashed, retry |
| - | - | no | **NO PROGRESS** — stagnation counter++ |
| BLOCKED | - | - | **BLOCKED** — mark [~], skip task |
| (timeout) | - | - | **TIMEOUT** — stash partial work |

## Safety Features

### Safe Rollback (no data loss)
On timeout, partial work is **stashed** (`git stash`), not destroyed. No more `git clean -fd`.

### Sensitive File Protection
`git add -A` is followed by automatic unstaging of sensitive file patterns (`.env*`, `*.pem`, `*.key`, etc.).

### Git Hook Respect
Pre-commit hooks run by default. Use `--skip-hooks` only when needed.

### Pre-flight Checks
Before the loop starts, the system validates: git repo status, `copilot_yolo` availability, Docker status, and AGENTS.md presence.

## Intelligence Features

### Error Context Propagation
When an iteration fails, the last 30 lines of agent output are saved and injected into the next iteration's prompt. The agent sees *why* the previous attempt failed.

### Failed Task Avoidance
Tasks that fail are tracked in `.ralph/failed-tasks.txt`. The agent prompt explicitly lists failed tasks with reasons, preventing repeated attempts at the same broken task.

### Adaptive Stagnation Recovery
Instead of immediately halting on stagnation:
1. **Stage 1:** "Try a completely different approach"
2. **Stage 2:** "Skip this task, try another one"
3. **Stage 3:** Model escalation (use smart model for one iteration)
4. **Stage 4:** Circuit breaker halt

### Smart Progress Context
Instead of blindly sending the last 60 lines of progress, the system builds a structured summary: completed task titles, recent failures with reasons, and only the last 3 iteration details. Reduces token waste by ~50-70%.

### Two-Phase Execution (optional)
With `--two-phase`, each iteration splits into:
1. **Selection** (cheap, fast): Agent picks one task
2. **Implementation** (focused): Agent implements only that specific task

Reduces prompt size and eliminates task-selection ambiguity.

## The Ralph Loop Philosophy

1. **Fresh context per iteration** — Each loop starts clean. Memory persists only through files.
2. **Tests as backpressure** — Quality gates reject bad work automatically.
3. **Agent self-reports completion** — Explicit signals via promise string + PRD mark.
4. **Adaptive recovery** — Stagnation triggers progressive recovery strategies before halting.
5. **Small atomic tasks** — Each task completable in one focused session.
6. **Human-readable state** — All state in Markdown files you can read and edit.
7. **Smart plan, cheap execute** — Expensive models for decomposition, cheap for implementation.
8. **No data loss** — Partial work is stashed, secrets are filtered, hooks are respected.

## Tips

- **Review the PRD** before starting the loop. The quality of the plan determines the quality of the output.
- **Create an AGENTS.md** in your project with specific instructions (test commands, conventions, etc.).
- **Start supervised** — watch the first few iterations, then let it run.
- **Small tasks win** — bias toward more, smaller tasks over fewer, larger ones.
- **Check `.ralph/failed-tasks.txt`** when the circuit breaker triggers — it shows failure patterns.
- **Use `--two-phase`** for projects with many tasks to reduce token usage.
