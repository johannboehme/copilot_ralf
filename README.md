# Ralph Loop

An autonomous AI coding agent that turns a one-line description into a working project. Describe what you want, review the plan, and let Ralph build it — task by task, commit by commit.

Ralph uses a **smart model** (like Claude Sonnet 4.5) to break your idea into small tasks, then hands those tasks to a **cheap, fast model** (like GPT-4.1) to implement them one at a time. After each task, it verifies the work, commits the changes, and moves on. You stay in control — you can review the plan, edit tasks, or stop at any time.

Powered by [copilot_here](https://github.com/GordonBeeming/copilot_here), which runs AI models through GitHub Copilot in a sandboxed Docker container.

## How It Works

```
 Your Prompt           "Build a REST API with auth"
      │
      ▼
 ┌──────────┐          Smart model breaks it into tasks
 │   Plan   │────────────────────────────────────────────► .ralph/prd.md
 └──────────┘
      │
      ▼  You review & edit the task list
 ┌──────────┐          Cheap model implements one task at a time
 │   Loop   │◄───────────────────────────────────────────► iterate
 └────┬─────┘
      │  Each iteration:
      │   1. Pick the next open task
      │   2. Implement it
      │   3. Run tests & linting
      │   4. Verify the work
      │   5. Commit and move on
      ▼
  All tasks done
```

## Setup

### 1. Install copilot_here

Ralph runs AI models through [copilot_here](https://github.com/GordonBeeming/copilot_here), which provides a `copilot_yolo` shell function. Follow the install instructions in that repo — it boils down to cloning it and sourcing a shell script:

```bash
git clone https://github.com/GordonBeeming/copilot_here.git ~/.copilot_here
echo 'source ~/.copilot_here/copilot_here.sh' >> ~/.zshrc   # or ~/.bashrc
source ~/.zshrc
```

### 2. Authenticate with GitHub

copilot_here uses GitHub Copilot under the hood, so you need to be logged in with the GitHub CLI:

```bash
# Install GitHub CLI if you don't have it
brew install gh              # macOS
# sudo apt install gh        # Ubuntu/Debian
# winget install GitHub.cli  # Windows

# Log in (this opens a browser for OAuth)
gh auth login

# Enable the Copilot extension
gh extension install github/gh-copilot
```

That's it for authentication — no extra API keys, no environment variables. If you can use `gh copilot` in your terminal, you're good to go.

### 3. Have Docker Running

copilot_here runs the AI agent inside a Docker container for safety. Make sure Docker (or a compatible runtime like OrbStack or Podman) is running:

```bash
docker info   # should print info without errors
```

### 4. Clone Ralph

```bash
git clone https://github.com/johannboehme/copilot_ralf.git
cd copilot_ralf
chmod +x *.sh
```

## Usage

### The Simple Way

Give Ralph a prompt and it handles the rest:

```bash
./ralph.sh "Build a CLI tool that converts CSV files to JSON"
```

This will:
1. Generate a task list (`.ralph/prd.md`) using a smart model
2. Pause so you can review and edit the tasks
3. Execute each task one at a time, committing as it goes

### Step by Step

If you prefer more control, run planning and execution separately:

```bash
# Step 1: Generate the plan
./ralph-plan.sh "Build a REST API with user authentication"

# Step 2: Review and edit .ralph/prd.md in your editor
#   - Reorder tasks
#   - Remove things you don't want
#   - Add details or constraints
#   - Adjust effort estimates

# Step 3: Run the loop
./ralph-loop.sh
```

### Skip the Review (Fully Autonomous)

For quick tasks where you trust the plan:

```bash
./ralph.sh --skip-review "Add a .gitignore for a Node.js project"
```

### Use Different Models

```bash
# Use a different planning model
./ralph.sh --plan-model gpt-5 "my prompt"

# Use a different execution model
./ralph.sh --loop-model claude-sonnet-4.5 "my prompt"

# Both
./ralph.sh --plan-model gpt-5 --loop-model gpt-4.1 "my prompt"
```

### Work in a Different Directory

```bash
./ralph.sh -p ./my-project "add a caching layer"
```

### Continue from an Existing Plan

If you already have a `.ralph/prd.md` (from a previous run or written by hand):

```bash
./ralph.sh --loop-only
```

### Two-Phase Execution

For large projects with many tasks, two-phase mode reduces token usage by splitting each iteration into a fast task-selection step and a focused implementation step:

```bash
./ralph.sh --two-phase "complex multi-service architecture"
```

## Setting Up Your Project with AGENTS.md

Ralph works best when it knows about your project. Create an `AGENTS.md` file in your project root to tell the agent what test commands to run, what conventions to follow, and any other rules.

A template is included:

```bash
cp /path/to/copilot_ralf/AGENTS.md.template ./AGENTS.md
```

Then fill in the sections — especially the verification commands:

```markdown
## Verification Commands

Run these after every change:

<!-- ralph:verify:start -->
```bash
npm test
npm run lint
npm run build
```
<!-- ralph:verify:end -->
```

The agent reads `AGENTS.md` at the start of every iteration, so this is the most reliable way to steer its behavior.

## What Happens Under the Hood

Ralph verifies every task through multiple signals before counting it as done:

- **Agent says it's done** — The agent outputs a completion marker
- **Task is checked off** — The agent marks the task `[x]` in the PRD
- **Files actually changed** — Git confirms real modifications were made
- **Tests pass** — Quality gates (if configured) reject bad work

If a task fails, Ralph doesn't just retry the same thing. It progressively adapts:
1. First, it asks the agent to try a different approach
2. Then, it skips the stuck task and moves on to another
3. If nothing works, it escalates to the smart model for one attempt
4. Finally, it stops and lets you take over

### Safety

- **No data loss** — On timeout, partial work is stashed with `git stash`, never deleted
- **Secrets stay out of git** — Sensitive files (`.env`, `*.pem`, `*.key`, etc.) are automatically unstaged before every commit
- **Git hooks run by default** — Pre-commit hooks are respected unless you explicitly pass `--skip-hooks`
- **Pre-flight checks** — Ralph validates your setup (git repo, Docker, copilot_yolo) before starting

## Configuration Reference

All options can be set via CLI flags or environment variables:

| Flag | Environment Variable | Default | What It Does |
|---|---|---|---|
| `--plan-model` | `RALPH_PLAN_MODEL` | `claude-sonnet-4.5` | Model used for planning |
| `--loop-model` | `RALPH_LOOP_MODEL` | `gpt-4.1` | Model used for execution |
| `-p, --project` | `RALPH_PROJECT_DIR` | `.` | Project directory to work in |
| `-n, --max-iterations` | `RALPH_MAX_ITERATIONS` | `50` | Max loop iterations before stopping |
| `--no-commit` | `RALPH_AUTO_COMMIT=false` | `true` | Auto-commit after each completed task |
| `--skip-hooks` | `RALPH_SKIP_HOOKS` | `false` | Skip git pre-commit hooks |
| `--skip-review` | `RALPH_SKIP_REVIEW` | `false` | Skip the PRD review step |
| `--two-phase` | `RALPH_TWO_PHASE` | `false` | Use two-phase task execution |
| `--verbose` | `RALPH_VERBOSE` | `false` | Log prompts and outputs to `.ralph/debug/` |
| | `RALPH_MAX_STAGNANT` | `3` | Failed iterations before circuit breaker triggers |
| | `RALPH_TASK_TIMEOUT` | `900` | Seconds per task before timeout (15 min) |

## Best Practices

**Write a good prompt.** The better your initial description, the better the plan. Be specific about what you want, what tech to use, and what the end result should look like.

**Always review the PRD.** The generated task list is the blueprint for everything that follows. Take a minute to read through it, reorder tasks, remove anything unnecessary, and add details where needed.

**Create an AGENTS.md.** This is the single most impactful thing you can do. Tell the agent how to run tests, what linting rules to follow, and what patterns to use. Without it, the agent guesses.

**Keep tasks small.** Lots of small, focused tasks work much better than a few large ones. If a task feels like it would take a human more than 30 minutes, it's probably too big — break it down.

**Start supervised.** Watch the first 2-3 iterations to make sure things are heading in the right direction. Once you're confident, let it run.

**Check failures.** When the loop stops, look at `.ralph/failed-tasks.txt` to see what went wrong and why. This often reveals missing dependencies, unclear requirements, or tasks that need to be rephrased.

**Use `--two-phase` for big projects.** When you have 10+ tasks, two-phase mode keeps each iteration focused and uses fewer tokens.

## File Overview

| File | What It Is |
|---|---|
| `ralph.sh` | Main entry point — runs planning then execution |
| `ralph-plan.sh` | Generates the task list from your prompt |
| `ralph-loop.sh` | Core loop that executes tasks one by one |
| `ralph-lib.sh` | Shared helpers (git safety, logging, PRD parsing) |
| `.ralph/prd.md` | The generated task list — review and edit this |
| `.ralph/progress.md` | Log of what happened each iteration |
| `.ralph/failed-tasks.txt` | Record of tasks that failed and why |
| `AGENTS.md.template` | Template for project-specific agent instructions |
