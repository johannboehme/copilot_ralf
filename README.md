# copilot_ralf — Ralph Loop for GitHub Copilot CLI

Autonomous AI coding loop powered by [copilot_here](https://github.com/GordonBeeming/copilot_here).

Uses a **smart model** to plan and a **cheap model** to execute — iteratively completing tasks from a human-readable Markdown PRD.

## How It Works

```
 Rough Prompt
      │
      ▼
┌─────────────┐    Smart Model (claude-sonnet-4.5)
│ ralph-plan  │───────────────────────────────────► prd.md
└─────────────┘
      │
      ▼  (human review)
┌─────────────┐    Cheap Model (gpt-4.1)
│ ralph-loop  │◄──────────────────────────────────► iterate
└──────┬──────┘
       │  for each task:
       │  1. Read prd.md + progress.md + AGENTS.md
       │  2. Implement the next task
       │  3. Run tests/lint/typecheck (backpressure)
       │  4. Agent marks task [x] in prd.md
       │  5. Agent outputs <ralph>TASK_DONE</ralph>
       │  6. Loop verifies: promise + PRD mark + file changes
       │  7. Git commit
       │  8. Repeat (or circuit breaker if stagnant)
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
./ralph-plan.sh "Build a REST API with user auth"   # generates prd.md
# ... review and edit prd.md ...
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

# Custom project directory
./ralph.sh -p ./my-project "add caching layer"
```

## File Structure

| File | Purpose |
|---|---|
| `ralph.sh` | Main entry point — plan + execute |
| `ralph-plan.sh` | Generates PRD from a rough prompt |
| `ralph-loop.sh` | Iterates over PRD tasks |
| `prd.md` | Task list (generated, human-editable) |
| `progress.md` | Iteration log and learnings |
| `AGENTS.md` | Project-specific agent instructions |
| `AGENTS.md.template` | Template for AGENTS.md |

## Configuration

All configuration via environment variables:

| Variable | Default | Description |
|---|---|---|
| `RALPH_PLAN_MODEL` | `claude-sonnet-4.5` | Model for task planning |
| `RALPH_LOOP_MODEL` | `gpt-4.1` | Model for task execution |
| `RALPH_PROJECT_DIR` | `.` | Project directory |
| `RALPH_MAX_ITERATIONS` | `50` | Max loop iterations |
| `RALPH_MAX_STAGNANT` | `3` | Stagnation circuit breaker threshold |
| `RALPH_TASK_TIMEOUT` | `900` | Seconds per task before timeout |
| `RALPH_AUTO_COMMIT` | `true` | Git commit after each task |

## Verification Strategy

The loop uses **layered verification** instead of naive file-change detection:

| Layer | Signal | Source | What it proves |
|---|---|---|---|
| 1 | Promise string `<ralph>TASK_DONE</ralph>` | Agent output | Agent believes task is done |
| 2 | Tests/lint/build pass | Agent runs them | Code quality gates pass |
| 3 | PRD checkbox `- [x]` | Agent edits prd.md | Agent marked specific task done |
| 4 | File changes (git diff) | Loop detects | Something was actually modified |
| 5 | Circuit breaker | Loop counts stagnation | Detects stuck/looping agents |
| 6 | Execution timeout | Loop enforces | Prevents infinite hangs |

**Decision matrix** (how the loop decides if a task is complete):

| Promise | PRD marked | Files changed | Verdict |
|---|---|---|---|
| DONE | [x] | yes | **VERIFIED** — commit and continue |
| - | [x] | yes | **COMPLETED** — trust PRD mark |
| DONE | - | yes | **PARTIAL** — accept, loop marks PRD |
| DONE | - | no | **SUSPICIOUS** — retry |
| - | - | yes | **INCOMPLETE** — agent crashed, retry |
| - | - | no | **NO PROGRESS** — stagnation counter++ |
| BLOCKED | - | - | **BLOCKED** — mark [~], skip task |
| (timeout) | - | - | **TIMEOUT** — revert partial changes |

## The Ralph Loop Philosophy

The Ralph Loop (Ralph Wiggum Technique) is based on these principles:

1. **Fresh context per iteration** — Each loop starts clean. Memory persists only through files (prd.md, progress.md, git history).
2. **Tests as backpressure** — Quality gates (tests, lint, typecheck) reject bad work automatically.
3. **Agent self-reports completion** — The loop doesn't guess; the agent explicitly signals via promise string + PRD mark.
4. **Circuit breakers prevent waste** — Stagnation detection and timeouts stop runaway loops.
5. **Small atomic tasks** — Each task should be completable in one focused session.
6. **Human-readable state** — All state is in Markdown files you can read and edit.
7. **Smart plan, cheap execute** — Use expensive models for decomposition, cheap models for implementation.

## Tips

- **Review the PRD** before starting the loop. The quality of the plan determines the quality of the output.
- **Create an AGENTS.md** in your project with specific instructions (test commands, conventions, etc.).
- **Start supervised** — watch the first few iterations, then let it run.
- **Small tasks win** — bias toward more, smaller tasks over fewer, larger ones.
- **Check progress.md** when the circuit breaker triggers — it shows what went wrong.
