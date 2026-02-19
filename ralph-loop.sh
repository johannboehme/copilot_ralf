#!/usr/bin/env bash
# ralph-loop.sh — The Ralph Loop: iterates over PRD tasks using a cheap model
# Usage: ./ralph-loop.sh [OPTIONS]
#
# Verification strategy (layered, per best practices):
#   Layer 1: Agent self-reports via promise string <ralph>TASK_DONE</ralph>
#   Layer 2: Agent must run verification commands (tests/lint) before claiming done
#   Layer 3: Agent marks the task [x] in prd.md itself (not the loop script)
#   Layer 4: Circuit breaker detects stagnation (no progress over N iterations)
#   Layer 5: Execution timeout per task prevents infinite hangs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${RALPH_PROJECT_DIR:-.}"

# Configuration
LOOP_MODEL="${RALPH_LOOP_MODEL:-gpt-4.1}"
PRD_FILE="${PROJECT_DIR}/prd.md"
PROGRESS_FILE="${PROJECT_DIR}/progress.md"
AGENTS_FILE="${PROJECT_DIR}/AGENTS.md"
MAX_ITERATIONS="${RALPH_MAX_ITERATIONS:-50}"
MAX_STAGNANT="${RALPH_MAX_STAGNANT:-3}"
TASK_TIMEOUT="${RALPH_TASK_TIMEOUT:-900}"  # 15 minutes per task
AUTO_COMMIT="${RALPH_AUTO_COMMIT:-true}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Run the Ralph Loop: iteratively complete tasks from prd.md."
    echo ""
    echo "Options:"
    echo "  -m, --model <model>       Model for task execution (default: ${LOOP_MODEL})"
    echo "  -p, --project <dir>       Project directory (default: current directory)"
    echo "  -n, --max-iterations <n>  Maximum loop iterations (default: ${MAX_ITERATIONS})"
    echo "  -s, --max-stagnant <n>    Stagnation circuit breaker (default: ${MAX_STAGNANT})"
    echo "  -t, --timeout <secs>      Timeout per task in seconds (default: ${TASK_TIMEOUT})"
    echo "  --no-commit               Don't auto-commit after each task"
    echo "  --dry-run                 Show what would be done without executing"
    echo "  -h, --help                Show this help message"
    echo ""
    echo "Environment variables:"
    echo "  RALPH_LOOP_MODEL          Model for execution (default: gpt-4.1)"
    echo "  RALPH_MAX_ITERATIONS      Max iterations (default: 50)"
    echo "  RALPH_MAX_STAGNANT        Stagnation limit before halt (default: 3)"
    echo "  RALPH_TASK_TIMEOUT        Seconds per task (default: 900)"
    echo "  RALPH_AUTO_COMMIT         Auto-commit after tasks (default: true)"
    echo "  RALPH_PROJECT_DIR         Project directory (default: .)"
}

# Parse arguments
DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--model) LOOP_MODEL="$2"; shift 2 ;;
        -p|--project) PROJECT_DIR="$2"; PRD_FILE="${2}/prd.md"; PROGRESS_FILE="${2}/progress.md"; AGENTS_FILE="${2}/AGENTS.md"; shift 2 ;;
        -n|--max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
        -s|--max-stagnant) MAX_STAGNANT="$2"; shift 2 ;;
        -t|--timeout) TASK_TIMEOUT="$2"; shift 2 ;;
        --no-commit) AUTO_COMMIT=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) echo -e "${RED}Unknown option: $1${NC}"; usage; exit 1 ;;
        *) echo -e "${RED}Unexpected argument: $1${NC}"; usage; exit 1 ;;
    esac
done

# Validate prerequisites
if [[ ! -f "${PRD_FILE}" ]]; then
    echo -e "${RED}Error: PRD file not found at ${PRD_FILE}${NC}"
    echo "Run ./ralph-plan.sh first to generate a PRD."
    exit 1
fi

if ! command -v copilot_yolo &>/dev/null; then
    echo -e "${RED}Error: copilot_yolo is not installed.${NC}"
    exit 1
fi

# ── Helper functions ──────────────────────────────────────────────

count_pending() {
    grep -c '^\- \[ \]' "${PRD_FILE}" 2>/dev/null || echo "0"
}

count_done() {
    grep -c '^\- \[x\]' "${PRD_FILE}" 2>/dev/null || echo "0"
}

detect_completed_task() {
    # Compare the PRD before/after to find which task was marked [x]
    # Returns the title of the newly completed task, or "unknown task"
    local prd_file="$1"
    local newly_done
    newly_done=$(git diff -- "${prd_file}" 2>/dev/null \
        | grep '^+- \[x\]' \
        | head -1 \
        | sed 's/^+- \[x\] \*\*\(.*\)\*\*.*/\1/' \
        | sed 's/\[effort:.*\]//' \
        | xargs 2>/dev/null) || true
    echo "${newly_done:-unknown task}"
}

snapshot_git_state() {
    # Capture a fingerprint of the working tree to detect real changes
    if git rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
        # Hash of: staged + unstaged diffs + list of untracked files
        {
            git diff 2>/dev/null
            git diff --cached 2>/dev/null
            git ls-files --others --exclude-standard 2>/dev/null
        } | shasum -a 256 | cut -d' ' -f1
    else
        echo "no-git"
    fi
}

log_progress() {
    local iteration="$1"
    local task_title="$2"
    local status="$3"
    local notes="${4:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Remove placeholder if present
    if grep -q "^_No iterations yet._$" "${PROGRESS_FILE}" 2>/dev/null; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' 's/^_No iterations yet._$//' "${PROGRESS_FILE}"
        else
            sed -i 's/^_No iterations yet._$//' "${PROGRESS_FILE}"
        fi
    fi

    # Append entry
    cat >> "${PROGRESS_FILE}" << EOF

### Iteration ${iteration} — ${timestamp}
- **Task:** ${task_title}
- **Status:** ${status}
- **Notes:** ${notes:-None}
EOF
}

auto_commit() {
    local task_title="$1"
    if [[ "${AUTO_COMMIT}" == true ]] && git rev-parse --is-inside-work-tree &>/dev/null; then
        git add -A 2>/dev/null || true
        if ! git diff --cached --quiet 2>/dev/null; then
            git commit -m "ralph: ${task_title}" --no-verify 2>/dev/null || true
            echo -e "${GREEN}  Committed: ralph: ${task_title}${NC}"
        fi
    fi
}

build_agent_prompt() {
    local iteration="$1"
    local pending="$2"
    local done="$3"

    # Read AGENTS.md if it exists
    local agents_context=""
    if [[ -f "${AGENTS_FILE}" ]]; then
        agents_context="$(cat "${AGENTS_FILE}")"
    fi

    # Read recent progress
    local progress_context=""
    if [[ -f "${PROGRESS_FILE}" ]]; then
        progress_context="$(tail -60 "${PROGRESS_FILE}")"
    fi

    cat <<PROMPT
You are an autonomous coding agent in a Ralph Loop (iteration ${iteration}).
${done} tasks completed, ${pending} tasks remaining.

## Project Instructions
${agents_context:-No AGENTS.md found. Use your best judgment for project conventions.}

## Recent Progress
${progress_context:-No previous progress.}

## Your Mission

1. Read prd.md to see the full task list.
2. Study which tasks are already done [x] and which are still open [ ].
3. **Choose the most important remaining task.** Consider:
   - Dependencies: does this task unblock others?
   - Foundation: does the project need this before other tasks can work?
   - Priority: higher-listed tasks are generally higher priority.
   - Context: what did previous iterations accomplish? What's the logical next step?
4. Implement ONLY that one task. Keep changes minimal and focused.
5. Follow existing code conventions and patterns in the project.
6. After implementing, run ALL verification commands you can find:
   - Tests (npm test, pytest, go test, cargo test, etc.)
   - Linting (npm run lint, ruff, eslint, etc.)
   - Type checking (tsc --noEmit, mypy, etc.)
   - Build (npm run build, go build, cargo build, etc.)
   Check AGENTS.md for project-specific commands.
7. If any verification fails, FIX the issues before continuing.
8. Once everything passes, mark your chosen task as done in prd.md:
   Change its line from "- [ ]" to "- [x]".

## Completion Signal

When (and ONLY when) you have:
  a) Chosen and implemented a task
  b) All verification commands pass (or no verification commands exist)
  c) Marked that task as [x] in prd.md

Then output this exact string on its own line:
<ralph>TASK_DONE</ralph>

If you could NOT complete any task (all remaining tasks are blocked), output:
<ralph>TASK_BLOCKED</ralph>

Do NOT output either signal until you are truly finished or truly blocked.

## Rules
- Do NOT modify progress.md — the loop manages that file.
- Work on exactly ONE task per iteration — not zero, not two.
- Do NOT output the completion signal prematurely.
- Keep changes minimal and focused on the single chosen task.
PROMPT
}

# ── Main Loop ─────────────────────────────────────────────────────

echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Ralph Loop — Starting          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Model:${NC}            ${LOOP_MODEL}"
echo -e "${YELLOW}PRD:${NC}              ${PRD_FILE}"
echo -e "${YELLOW}Max iterations:${NC}   ${MAX_ITERATIONS}"
echo -e "${YELLOW}Stagnation limit:${NC} ${MAX_STAGNANT} iterations"
echo -e "${YELLOW}Task timeout:${NC}     ${TASK_TIMEOUT}s"
echo -e "${YELLOW}Auto-commit:${NC}      ${AUTO_COMMIT}"
echo ""

iteration=0
stagnant_count=0
last_pending=$(count_pending)

while [[ ${iteration} -lt ${MAX_ITERATIONS} ]]; do
    iteration=$((iteration + 1))

    # Check if all tasks are done (agent marked them in prd.md)
    PENDING=$(count_pending)
    DONE=$(count_done)

    if [[ "${PENDING}" -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║    All tasks completed!              ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
        echo ""
        echo -e "Completed ${DONE} tasks in ${iteration} iterations."
        echo -e "Progress log: ${PROGRESS_FILE}"
        exit 0
    fi

    # ── Circuit breaker: stagnation detection ──
    if [[ "${PENDING}" -eq "${last_pending}" ]] && [[ ${iteration} -gt 1 ]]; then
        stagnant_count=$((stagnant_count + 1))
        if [[ ${stagnant_count} -ge ${MAX_STAGNANT} ]]; then
            echo ""
            echo -e "${RED}╔══════════════════════════════════════╗${NC}"
            echo -e "${RED}║  CIRCUIT BREAKER: Stagnation detected║${NC}"
            echo -e "${RED}╚══════════════════════════════════════╝${NC}"
            echo ""
            echo -e "${RED}No task was completed in the last ${MAX_STAGNANT} iterations.${NC}"
            echo -e "${RED}The agent may be stuck or the task may be too complex.${NC}"
            echo ""
            echo -e "${YELLOW}Options:${NC}"
            echo -e "  1. Review ${PRD_FILE} — break the current task into smaller subtasks"
            echo -e "  2. Add more detail to AGENTS.md"
            echo -e "  3. Run again with a different model: --model <model>"
            echo -e "  4. Run again to retry: ./ralph-loop.sh"
            log_progress "${iteration}" "(circuit breaker)" "halted" "No progress for ${MAX_STAGNANT} iterations"
            exit 2
        fi
    else
        stagnant_count=0
    fi
    last_pending="${PENDING}"

    echo -e "${CYAN}┌──────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│ Iteration ${iteration}/${MAX_ITERATIONS} (${DONE} done, ${PENDING} pending)${NC}"
    echo -e "${CYAN}│ Agent will choose the next task${NC}"
    echo -e "${CYAN}└──────────────────────────────────────┘${NC}"

    if [[ "${DRY_RUN}" == true ]]; then
        echo -e "${YELLOW}  [DRY RUN] Would send PRD to ${LOOP_MODEL}${NC}"
        continue
    fi

    # Snapshot git state before execution
    STATE_BEFORE=$(snapshot_git_state)

    # Build the prompt — agent gets full PRD and chooses its own task
    AGENT_PROMPT=$(build_agent_prompt "${iteration}" "${PENDING}" "${DONE}")

    # Execute via copilot_yolo with timeout
    echo -e "${GREEN}  Executing with ${LOOP_MODEL}...${NC}"

    TASK_OUTPUT=""
    TASK_EXIT=0
    if [[ "${TASK_TIMEOUT}" -gt 0 ]]; then
        TASK_OUTPUT=$(timeout "${TASK_TIMEOUT}" copilot_yolo --model "${LOOP_MODEL}" --no-pull -p "${AGENT_PROMPT}" 2>&1) || TASK_EXIT=$?
    else
        TASK_OUTPUT=$(copilot_yolo --model "${LOOP_MODEL}" --no-pull -p "${AGENT_PROMPT}" 2>&1) || TASK_EXIT=$?
    fi

    # ── Evaluate result using multiple signals ──

    # Detect which task the agent completed (from PRD diff)
    COMPLETED_TASK=$(detect_completed_task "${PRD_FILE}")

    # Signal 1: Did the agent output the promise string?
    PROMISE_DONE=false
    PROMISE_BLOCKED=false
    if echo "${TASK_OUTPUT}" | grep -q '<ralph>TASK_DONE</ralph>'; then
        PROMISE_DONE=true
    fi
    if echo "${TASK_OUTPUT}" | grep -q '<ralph>TASK_BLOCKED</ralph>'; then
        PROMISE_BLOCKED=true
    fi

    # Signal 2: Did the agent mark the task as [x] in prd.md?
    NEW_PENDING=$(count_pending)
    TASK_MARKED_DONE=false
    if [[ "${NEW_PENDING}" -lt "${PENDING}" ]]; then
        TASK_MARKED_DONE=true
    fi

    # Signal 3: Did any files actually change?
    STATE_AFTER=$(snapshot_git_state)
    FILES_CHANGED=false
    if [[ "${STATE_BEFORE}" != "${STATE_AFTER}" ]]; then
        FILES_CHANGED=true
    fi

    # Signal 4: Did the execution time out?
    TIMED_OUT=false
    if [[ ${TASK_EXIT} -eq 124 ]]; then
        TIMED_OUT=true
    fi

    # ── Decision logic ──

    if [[ "${TIMED_OUT}" == true ]]; then
        echo -e "${RED}  TIMEOUT: Task exceeded ${TASK_TIMEOUT}s limit${NC}"
        log_progress "${iteration}" "${COMPLETED_TASK}" "timeout" "Exceeded ${TASK_TIMEOUT}s. Files changed: ${FILES_CHANGED}"
        # Don't mark done — agent may have left things half-baked
        if [[ "${FILES_CHANGED}" == true ]]; then
            echo -e "${YELLOW}  Warning: Files were modified before timeout. Review manually.${NC}"
            # Revert partial changes to avoid corrupted state
            echo -e "${YELLOW}  Reverting partial changes...${NC}"
            git checkout -- . 2>/dev/null || true
            git clean -fd 2>/dev/null || true
        fi

    elif [[ "${PROMISE_BLOCKED}" == true ]]; then
        echo -e "${RED}  BLOCKED: Agent reported it cannot complete a task${NC}"
        log_progress "${iteration}" "${COMPLETED_TASK}" "blocked" "Agent self-reported blocker"
        # The agent should have marked the blocked task itself.
        # If it didn't, the stagnation circuit breaker will eventually catch it.

    elif [[ "${PROMISE_DONE}" == true ]] && [[ "${TASK_MARKED_DONE}" == true ]]; then
        # Best case: agent said done AND marked it in the PRD
        echo -e "${GREEN}  VERIFIED: Task completed (promise + PRD marked)${NC}"
        log_progress "${iteration}" "${COMPLETED_TASK}" "completed" "Verified: promise string + PRD checkbox"
        auto_commit "${COMPLETED_TASK}"

    elif [[ "${TASK_MARKED_DONE}" == true ]] && [[ "${PROMISE_DONE}" == false ]]; then
        # Agent marked PRD but didn't output promise — trust the PRD as primary signal
        echo -e "${GREEN}  COMPLETED: Task marked done in PRD (no promise string)${NC}"
        log_progress "${iteration}" "${COMPLETED_TASK}" "completed" "PRD marked, no promise string"
        auto_commit "${COMPLETED_TASK}"

    elif [[ "${PROMISE_DONE}" == true ]] && [[ "${TASK_MARKED_DONE}" == false ]]; then
        # Agent said done but forgot to mark PRD
        if [[ "${FILES_CHANGED}" == true ]]; then
            echo -e "${YELLOW}  PARTIAL: Agent claimed done but didn't mark PRD. Files changed.${NC}"
            echo -e "${YELLOW}  Committing work. Next iteration should mark the PRD.${NC}"
            log_progress "${iteration}" "${COMPLETED_TASK}" "partial" "Promise + file changes but PRD not marked"
            auto_commit "${COMPLETED_TASK}"
            # Don't try to guess which task to mark — let the next iteration handle it
        else
            echo -e "${YELLOW}  SUSPICIOUS: Agent claimed done but no file changes and no PRD mark${NC}"
            log_progress "${iteration}" "${COMPLETED_TASK}" "suspicious" "Promise without evidence — retrying"
        fi

    elif [[ "${FILES_CHANGED}" == true ]] && [[ "${PROMISE_DONE}" == false ]] && [[ "${TASK_MARKED_DONE}" == false ]]; then
        # Files changed but no completion signal — agent may have crashed mid-task
        echo -e "${YELLOW}  INCOMPLETE: Files changed but no completion signal${NC}"
        echo -e "${YELLOW}  Agent may have crashed or hit an error. Leaving for next iteration.${NC}"
        log_progress "${iteration}" "${COMPLETED_TASK}" "incomplete" "Files changed, no completion signal — will retry"
        # Don't mark done, don't commit — let the next iteration see the partial work
        # and either finish or clean up

    else
        # No changes, no signals — agent did nothing
        echo -e "${YELLOW}  NO PROGRESS: No changes, no completion signal${NC}"
        log_progress "${iteration}" "${COMPLETED_TASK}" "no-progress" "No file changes, no signals"
    fi

    echo ""
done

echo -e "${YELLOW}Maximum iterations (${MAX_ITERATIONS}) reached.${NC}"
REMAINING=$(count_pending)
BLOCKED=$(grep -c '^\- \[\~\]' "${PRD_FILE}" 2>/dev/null || echo "0")
echo -e "${YELLOW}${REMAINING} tasks pending, ${BLOCKED} blocked. Run again to continue.${NC}"
exit 1
