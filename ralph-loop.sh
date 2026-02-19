#!/usr/bin/env bash
# ralph-loop.sh — The Ralph Loop: iterates over PRD tasks using a cheap model
# Usage: ./ralph-loop.sh [OPTIONS]
#
# Verification strategy (layered):
#   Layer 1: Agent self-reports via promise string <ralph>TASK_DONE</ralph>
#   Layer 2: Agent runs verification commands (tests/lint) before claiming done
#   Layer 3: Agent marks the task [x] in prd.md
#   Layer 4: Loop detects file changes via git state snapshots
#   Layer 5: Circuit breaker with adaptive recovery on stagnation
#   Layer 6: Execution timeout per task prevents infinite hangs

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ralph-lib.sh"

# ── Configuration ─────────────────────────────────────────────────

PROJECT_DIR="${RALPH_PROJECT_DIR:-.}"
LOOP_MODEL="${RALPH_LOOP_MODEL:-gpt-4.1}"
PLAN_MODEL="${RALPH_PLAN_MODEL:-claude-sonnet-4.5}"
MAX_ITERATIONS="${RALPH_MAX_ITERATIONS:-50}"
MAX_STAGNANT="${RALPH_MAX_STAGNANT:-3}"
TASK_TIMEOUT="${RALPH_TASK_TIMEOUT:-900}"
AUTO_COMMIT="${RALPH_AUTO_COMMIT:-true}"
SKIP_HOOKS="${RALPH_SKIP_HOOKS:-false}"
TWO_PHASE="${RALPH_TWO_PHASE:-false}"
VERBOSE="${RALPH_VERBOSE:-false}"

init_ralph_dir "${PROJECT_DIR}"

AGENTS_FILE="${PROJECT_DIR}/AGENTS.md"

# ── Usage ─────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Run the Ralph Loop: iteratively complete tasks from .ralph/prd.md.

Options:
  -m, --model <model>       Model for task execution (default: ${LOOP_MODEL})
  -p, --project <dir>       Project directory (default: current directory)
  -n, --max-iterations <n>  Maximum loop iterations (default: ${MAX_ITERATIONS})
  -s, --max-stagnant <n>    Stagnation circuit breaker (default: ${MAX_STAGNANT})
  -t, --timeout <secs>      Timeout per task in seconds (default: ${TASK_TIMEOUT})
  --no-commit               Don't auto-commit after each task
  --skip-hooks              Skip git pre-commit hooks on commits
  --two-phase               Use two-phase execution (select task, then implement)
  --verbose                 Log prompts and outputs to .ralph/debug/
  --dry-run                 Show what would be done without executing
  -h, --help                Show this help message

Environment variables:
  RALPH_LOOP_MODEL          Model for execution (default: gpt-4.1)
  RALPH_PLAN_MODEL          Smart model for escalation (default: claude-sonnet-4.5)
  RALPH_MAX_ITERATIONS      Max iterations (default: 50)
  RALPH_MAX_STAGNANT        Stagnation limit before halt (default: 3)
  RALPH_TASK_TIMEOUT        Seconds per task (default: 900)
  RALPH_AUTO_COMMIT         Auto-commit after tasks (default: true)
  RALPH_SKIP_HOOKS          Skip pre-commit hooks (default: false)
  RALPH_TWO_PHASE           Two-phase task execution (default: false)
  RALPH_VERBOSE             Log prompts/outputs to .ralph/debug/ (default: false)
EOF
}

# ── Parse Arguments ───────────────────────────────────────────────

DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--model) LOOP_MODEL="$2"; shift 2 ;;
        -p|--project)
            PROJECT_DIR="$2"
            init_ralph_dir "${PROJECT_DIR}"
            AGENTS_FILE="${PROJECT_DIR}/AGENTS.md"
            shift 2 ;;
        -n|--max-iterations) MAX_ITERATIONS="$2"; shift 2 ;;
        -s|--max-stagnant) MAX_STAGNANT="$2"; shift 2 ;;
        -t|--timeout) TASK_TIMEOUT="$2"; shift 2 ;;
        --no-commit) AUTO_COMMIT=false; shift ;;
        --skip-hooks) SKIP_HOOKS=true; shift ;;
        --two-phase) TWO_PHASE=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) error "Unknown option: $1"; usage; exit 1 ;;
        *) error "Unexpected argument: $1"; usage; exit 1 ;;
    esac
done

# ── Validate Prerequisites ───────────────────────────────────────

if [[ ! -f "${RALPH_PRD}" ]]; then
    error "PRD file not found at ${RALPH_PRD}"
    echo "Run ./ralph-plan.sh first to generate a PRD."
    exit 1
fi

_ralph_load_copilot
if ! type copilot_yolo &>/dev/null; then
    error "copilot_yolo is not installed."
    echo "Install from: https://github.com/GordonBeeming/copilot_here"
    exit 1
fi

# Validate PRD format
if ! validate_prd "${RALPH_PRD}"; then
    error "PRD validation failed. Fix the issues above before running the loop."
    exit 1
fi

# Pre-flight checks (skip if already done by ralph.sh)
if [[ "${RALPH_PREFLIGHT_DONE:-}" != "1" ]]; then
    preflight_check "${PROJECT_DIR}" || exit 1
fi

# ── Prompt Builders ───────────────────────────────────────────────

build_static_prompt() {
    # Static content first (prompt-caching friendly)
    local agents_context=""
    if [[ -f "${AGENTS_FILE}" ]]; then
        agents_context="$(cat "${AGENTS_FILE}")"
    fi

    cat <<'STATIC'
## Rules

- Work on exactly ONE task per iteration — not zero, not two.
- Keep changes minimal and focused on the single chosen task.
- Follow existing code conventions and patterns in the project.
- After implementing, run ALL verification commands:
  - Tests (npm test, pytest, go test, cargo test, etc.)
  - Linting (npm run lint, ruff, eslint, etc.)
  - Type checking (tsc --noEmit, mypy, etc.)
  - Build (npm run build, go build, cargo build, etc.)
  - Check AGENTS.md for project-specific commands.
- If verification fails, FIX the issues before continuing.
- Once done, mark the task as [x] in prd.md.
- Do NOT modify progress.md — the loop manages that file.
- Do NOT output the completion signal prematurely.

## Completion Signal

When (and ONLY when) you have:
  a) Implemented the task
  b) All verification passes (or no verification commands exist)
  c) Marked the task [x] in prd.md

Output this exact string on its own line:
<ralph>TASK_DONE</ralph>

If ALL remaining tasks are blocked, output:
<ralph>TASK_BLOCKED</ralph>
STATIC

    if [[ -n "${agents_context}" ]]; then
        echo ""
        echo "## Project Instructions"
        echo ""
        echo "${agents_context}"
    fi
}

build_dynamic_prompt() {
    local iteration="$1"
    local pending="$2"
    local done="$3"
    local stagnant_count="$4"
    local last_error="${5:-}"

    # Dynamic content: changes each iteration
    cat <<DYNAMIC
You are an autonomous coding agent in a Ralph Loop (iteration ${iteration}).
${done} tasks completed, ${pending} tasks remaining.

## Your Mission

1. Read .ralph/prd.md to see the full task list.
2. Study which tasks are done [x] and which are open [ ].
3. Choose the most important remaining task. Consider:
   - Dependencies: does this task unblock others?
   - Foundation: does the project need this before other tasks?
   - Priority: higher-listed = higher priority.
   - Context: what did previous iterations accomplish?
4. Implement ONLY that one task.
5. Run all verification, fix any failures.
6. Mark the task [x] in .ralph/prd.md.
7. Output the completion signal.
DYNAMIC

    # Failed task avoidance
    local failed_tasks
    failed_tasks=$(get_failed_tasks)
    if [[ -n "${failed_tasks}" ]]; then
        echo ""
        echo "## Tasks to SKIP (failed in previous iterations)"
        echo "Do NOT attempt these tasks — they have failed before:"
        echo "${failed_tasks}"
        echo ""
        echo "Focus on other tasks instead. Only retry a failed task if you have a clearly different approach."
    fi

    # Adaptive stagnation hints
    if [[ "${stagnant_count}" -ge 1 ]]; then
        echo ""
        echo "## IMPORTANT: Stagnation Warning"
        if [[ "${stagnant_count}" -eq 1 ]]; then
            echo "The last iteration made no progress. Try a COMPLETELY different approach."
            echo "Consider: simplifying the task, using different tools, or breaking it down."
        elif [[ "${stagnant_count}" -ge 2 ]]; then
            echo "Multiple iterations have made no progress. You MUST skip the task you have been"
            echo "attempting and choose a DIFFERENT task from the PRD. If all tasks seem blocked,"
            echo "output <ralph>TASK_BLOCKED</ralph>."
        fi
    fi

    # Last error context
    if [[ -n "${last_error}" ]]; then
        echo ""
        echo "## Last Failure Context"
        echo "The previous iteration failed. Here is the error output:"
        echo '```'
        echo "${last_error}"
        echo '```'
        echo "Use this context to avoid the same mistake."
    fi

    # Progress summary
    local progress_summary
    progress_summary=$(build_progress_summary)
    if [[ -n "${progress_summary}" ]] && [[ "${progress_summary}" != "No previous progress." ]]; then
        echo ""
        echo "## Recent Progress"
        echo "${progress_summary}"
    fi
}

build_task_selection_prompt() {
    local pending="$1"
    local done="$2"

    local failed_tasks
    failed_tasks=$(get_failed_tasks)

    cat <<SELECT
You are a task selector for a Ralph Loop.
${done} tasks completed, ${pending} tasks remaining.

Read .ralph/prd.md. Choose the single most important remaining task.
Consider: dependencies, foundation tasks, priority order.
SELECT

    if [[ -n "${failed_tasks}" ]]; then
        echo ""
        echo "Do NOT select these failed tasks:"
        echo "${failed_tasks}"
    fi

    echo ""
    echo "Output ONLY the exact task title from the PRD, nothing else."
    echo "Format: TASK: <exact task title>"
}

build_implementation_prompt() {
    local task_title="$1"

    cat <<IMPL
You are an autonomous coding agent. Implement this specific task:

**${task_title}**

Read .ralph/prd.md for the full task description, files to modify, and acceptance criteria.
IMPL

    # Include static rules
    build_static_prompt

    echo ""
    echo "After implementation is complete and verified, mark this task [x] in .ralph/prd.md"
    echo "and output: <ralph>TASK_DONE</ralph>"
}

# ── Main Loop ─────────────────────────────────────────────────────

INITIAL_PENDING=$(count_pending)
INITIAL_DONE=$(count_done)
INITIAL_TOTAL=$((INITIAL_PENDING + INITIAL_DONE + $(count_blocked)))

echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║       Ralph Loop — Starting          ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${YELLOW}Model:${NC} ${LOOP_MODEL}  ${DIM}|${NC}  ${YELLOW}Escalation:${NC} ${PLAN_MODEL}"
echo -e "  ${YELLOW}Limits:${NC} ${MAX_ITERATIONS} iters, ${MAX_STAGNANT} stagnant, $(format_duration "${TASK_TIMEOUT}")/task"
echo -e "  ${YELLOW}Options:${NC} commit=${AUTO_COMMIT} two-phase=${TWO_PHASE} verbose=${VERBOSE}"
echo ""
print_progress_bar "${INITIAL_DONE}" "${INITIAL_TOTAL}"
echo ""

# Preview first pending tasks
PREVIEW_TASKS=$(grep '^\- \[ \]' "${RALPH_PRD}" 2>/dev/null \
    | head -5 \
    | sed 's/^- \[ \] \*\*\(.*\)\*\*.*/\1/' \
    | sed 's/\[effort:.*\]//' || true)
if [[ -n "${PREVIEW_TASKS}" ]]; then
    echo -e "  ${DIM}Next tasks:${NC}"
    while IFS= read -r t; do
        t=$(echo "${t}" | xargs 2>/dev/null)
        if [[ ${#t} -gt 50 ]]; then t="${t:0:47}..."; fi
        echo -e "    ${DIM}○${NC} ${t}"
    done <<< "${PREVIEW_TASKS}"
    if [[ "${INITIAL_PENDING}" -gt 5 ]]; then
        echo -e "    ${DIM}... and $((INITIAL_PENDING - 5)) more${NC}"
    fi
    echo ""
fi

# Create debug directory if verbose
if [[ "${VERBOSE}" == true ]]; then
    mkdir -p "${RALPH_DIR}/debug"
fi

LOOP_START_TIME=$(date +%s)
iteration=0
stagnant_count=0
last_pending=$(count_pending)
last_error_context=""

# Cache static prompt (doesn't change between iterations)
STATIC_PROMPT=$(build_static_prompt)

while [[ ${iteration} -lt ${MAX_ITERATIONS} ]]; do
    iteration=$((iteration + 1))
    ITER_START=$(date +%s)

    # Check if all tasks are done
    PENDING=$(count_pending)
    DONE=$(count_done)

    if [[ "${PENDING}" -eq 0 ]]; then
        echo ""
        echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
        echo -e "${GREEN}║    All tasks completed!              ║${NC}"
        echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
        print_summary "${iteration}" "${LOOP_START_TIME}" "$(date +%s)"
        exit 0
    fi

    # ── Stagnation detection with adaptive recovery ──
    if [[ "${PENDING}" -eq "${last_pending}" ]] && [[ ${iteration} -gt 1 ]]; then
        stagnant_count=$((stagnant_count + 1))

        # Adaptive recovery stages
        if [[ ${stagnant_count} -eq 1 ]]; then
            warn "  Stagnation detected (1/${MAX_STAGNANT}). Injecting different-approach hint."
        elif [[ ${stagnant_count} -eq 2 ]]; then
            warn "  Stagnation persists (2/${MAX_STAGNANT}). Forcing task skip."
        elif [[ ${stagnant_count} -eq "${MAX_STAGNANT}" ]]; then
            warn "  Stagnation critical (${MAX_STAGNANT}/${MAX_STAGNANT}). Escalating to smart model: ${PLAN_MODEL}"
        elif [[ ${stagnant_count} -gt $((MAX_STAGNANT + 1)) ]]; then
            echo ""
            echo -e "${RED}╔══════════════════════════════════════╗${NC}"
            echo -e "${RED}║  CIRCUIT BREAKER: Stagnation halt    ║${NC}"
            echo -e "${RED}╚══════════════════════════════════════╝${NC}"
            echo ""
            error "No task completed in ${stagnant_count} iterations (limit: ${MAX_STAGNANT}+2)."
            echo ""
            echo -e "${YELLOW}Options:${NC}"
            echo "  1. Review ${RALPH_PRD} — break tasks into smaller subtasks"
            echo "  2. Add more detail to AGENTS.md"
            echo "  3. Run again with a different model: --model <model>"
            echo "  4. Check .ralph/failed-tasks.txt for failure patterns"
            log_progress "${iteration}" "(circuit breaker)" "halted" "No progress for ${stagnant_count} iterations"
            print_summary "${iteration}" "${LOOP_START_TIME}" "$(date +%s)"
            exit 2
        fi
    else
        stagnant_count=0
    fi
    last_pending="${PENDING}"

    # Choose model (escalate on final stagnation stage)
    CURRENT_MODEL="${LOOP_MODEL}"
    if [[ ${stagnant_count} -eq ${MAX_STAGNANT} ]]; then
        CURRENT_MODEL="${PLAN_MODEL}"
        info "  Model escalation: using ${PLAN_MODEL} for this iteration"
    fi

    # Parse effort level from the next pending task for timeout adjustment
    EFFECTIVE_TIMEOUT="${TASK_TIMEOUT}"
    NEXT_EFFORT=$(grep -m1 '^\- \[ \]' "${RALPH_PRD}" 2>/dev/null \
        | grep -oE '\[effort: *(low|medium|high)\]' \
        | sed 's/\[effort: *//;s/\]//' || true)
    case "${NEXT_EFFORT}" in
        low)    EFFECTIVE_TIMEOUT=$((TASK_TIMEOUT / 2)) ;;
        high)   EFFECTIVE_TIMEOUT=$((TASK_TIMEOUT * 2)) ;;
        *)      EFFECTIVE_TIMEOUT="${TASK_TIMEOUT}" ;;
    esac

    TOTAL_TASKS=$((DONE + PENDING + $(count_blocked)))
    ELAPSED=$(($(date +%s) - LOOP_START_TIME))
    NEXT_TASK=$(get_next_pending_task)

    print_dashboard "${iteration}" "${MAX_ITERATIONS}" "${CURRENT_MODEL}" \
        "${stagnant_count}" "${DONE}" "${TOTAL_TASKS}" \
        "${NEXT_TASK}" "${ELAPSED}" "${EFFECTIVE_TIMEOUT}"

    if [[ "${DRY_RUN}" == true ]]; then
        warn "  [DRY RUN] Would send PRD to ${CURRENT_MODEL}"
        ITER_END=$(date +%s)
        continue
    fi

    # Snapshot git state before execution
    STATE_BEFORE=$(snapshot_git_state)

    # ── Execute ──

    TASK_OUTPUT=""
    TASK_EXIT=0

    if [[ "${TWO_PHASE}" == true ]]; then
        # Phase 1: Task selection (short, cheap)
        info "  Phase 1: Selecting task..."
        SELECT_PROMPT=$(build_task_selection_prompt "${PENDING}" "${DONE}")

        SELECTED_TASK=""
        SELECTED_TASK=$(run_copilot_yolo_with_timeout 120 --model "${CURRENT_MODEL}" --no-pull -p "${SELECT_PROMPT}" 2>&1) || true
        SELECTED_TASK=$(echo "${SELECTED_TASK}" | grep '^TASK:' | head -1 | sed 's/^TASK: *//')

        if [[ -z "${SELECTED_TASK}" ]]; then
            warn "  Task selection failed, falling back to single-phase"
            # Fall back to single-phase
            AGENT_PROMPT="${STATIC_PROMPT}

$(build_dynamic_prompt "${iteration}" "${PENDING}" "${DONE}" "${stagnant_count}" "${last_error_context}")"
        else
            info "  Selected: ${SELECTED_TASK}"
            info "  Phase 2: Implementing..."
            AGENT_PROMPT=$(build_implementation_prompt "${SELECTED_TASK}")
        fi
    else
        # Single-phase: agent chooses and implements
        AGENT_PROMPT="${STATIC_PROMPT}

$(build_dynamic_prompt "${iteration}" "${PENDING}" "${DONE}" "${stagnant_count}" "${last_error_context}")"
    fi

    # Log prompt if verbose
    if [[ "${VERBOSE}" == true ]]; then
        echo "${AGENT_PROMPT}" > "${RALPH_DIR}/debug/iter-${iteration}-prompt.txt"
        dim "  [verbose] Prompt saved to .ralph/debug/iter-${iteration}-prompt.txt"
    fi

    # Execute via copilot_yolo
    echo -e "  ${DIM}Executing with ${CURRENT_MODEL}...${NC}"

    TASK_OUTPUT_FILE=$(ralph_mktemp)
    export RALPH_OUTPUT_FILE="${TASK_OUTPUT_FILE}"

    start_output_peek "${TASK_OUTPUT_FILE}"

    if [[ "${EFFECTIVE_TIMEOUT}" -gt 0 ]]; then
        run_copilot_yolo_with_timeout "${EFFECTIVE_TIMEOUT}" --model "${CURRENT_MODEL}" --no-pull -p "${AGENT_PROMPT}" || TASK_EXIT=$?
    else
        run_copilot_yolo --model "${CURRENT_MODEL}" --no-pull -p "${AGENT_PROMPT}" || TASK_EXIT=$?
    fi

    unset RALPH_OUTPUT_FILE
    stop_output_peek

    TASK_OUTPUT=$(cat "${TASK_OUTPUT_FILE}" 2>/dev/null)
    rm -f "${TASK_OUTPUT_FILE}"

    ITER_END=$(date +%s)
    ITER_DURATION=$((ITER_END - ITER_START))

    # Log output if verbose
    if [[ "${VERBOSE}" == true ]]; then
        echo "${TASK_OUTPUT}" > "${RALPH_DIR}/debug/iter-${iteration}-output.txt"
        dim "  [verbose] Output saved to .ralph/debug/iter-${iteration}-output.txt (${ITER_DURATION}s)"
    fi

    # ── Evaluate result using multiple signals ──

    COMPLETED_TASK=$(detect_completed_task)

    # Signal 1: Promise string
    PROMISE_DONE=false
    PROMISE_BLOCKED=false
    if echo "${TASK_OUTPUT}" | grep -q '<ralph>TASK_DONE</ralph>'; then
        PROMISE_DONE=true
    fi
    if echo "${TASK_OUTPUT}" | grep -q '<ralph>TASK_BLOCKED</ralph>'; then
        PROMISE_BLOCKED=true
    fi

    # Signal 2: PRD checkbox change
    NEW_PENDING=$(count_pending)
    TASK_MARKED_DONE=false
    if [[ "${NEW_PENDING}" -lt "${PENDING}" ]]; then
        TASK_MARKED_DONE=true
    fi

    # Signal 3: File changes
    STATE_AFTER=$(snapshot_git_state)
    FILES_CHANGED=false
    if [[ "${STATE_BEFORE}" != "${STATE_AFTER}" ]]; then
        FILES_CHANGED=true
    fi

    # Signal 4: Timeout
    TIMED_OUT=false
    if [[ ${TASK_EXIT} -eq 124 ]]; then
        TIMED_OUT=true
    fi

    # Extract error context for failed iterations (last 30 lines)
    ERROR_TAIL=""
    if [[ "${PROMISE_DONE}" == false ]] && [[ "${TASK_MARKED_DONE}" == false ]]; then
        ERROR_TAIL=$(echo "${TASK_OUTPUT}" | tail -50)
    fi

    # ── Decision logic ──

    if [[ "${TIMED_OUT}" == true ]]; then
        print_verdict "timeout" "${COMPLETED_TASK}" "${ITER_DURATION}" \
            "exceeded $(format_duration "${EFFECTIVE_TIMEOUT}") limit"
        log_progress "${iteration}" "${COMPLETED_TASK}" "timeout" \
            "Exceeded ${EFFECTIVE_TIMEOUT}s. Files changed: ${FILES_CHANGED}" \
            "${ERROR_TAIL}" "${ITER_DURATION}"
        mark_task_failed "${COMPLETED_TASK}" "${iteration}" "timeout after ${EFFECTIVE_TIMEOUT}s"
        if [[ "${FILES_CHANGED}" == true ]]; then
            dim "    Partial work stashed (not destroyed)."
            safe_revert "${iteration}" "timeout"
        fi
        last_error_context="Task timed out after ${EFFECTIVE_TIMEOUT}s"

    elif [[ "${PROMISE_BLOCKED}" == true ]]; then
        print_verdict "blocked" "${COMPLETED_TASK}" "${ITER_DURATION}" \
            "agent reported all remaining tasks are blocked"
        log_progress "${iteration}" "${COMPLETED_TASK}" "blocked" \
            "Agent self-reported blocker" "" "${ITER_DURATION}"
        last_error_context=""

    elif [[ "${PROMISE_DONE}" == true ]] && [[ "${TASK_MARKED_DONE}" == true ]]; then
        print_verdict "verified" "${COMPLETED_TASK}" "${ITER_DURATION}" \
            "promise + PRD marked"
        log_progress "${iteration}" "${COMPLETED_TASK}" "completed" \
            "Verified: promise + PRD checkbox" "" "${ITER_DURATION}"
        if [[ "${AUTO_COMMIT}" == true ]]; then
            safe_commit "ralph: ${COMPLETED_TASK}" "${SKIP_HOOKS}"
        fi
        last_error_context=""

    elif [[ "${TASK_MARKED_DONE}" == true ]] && [[ "${PROMISE_DONE}" == false ]]; then
        print_verdict "completed" "${COMPLETED_TASK}" "${ITER_DURATION}" \
            "PRD marked done (no promise string)"
        log_progress "${iteration}" "${COMPLETED_TASK}" "completed" \
            "PRD marked, no promise string" "" "${ITER_DURATION}"
        if [[ "${AUTO_COMMIT}" == true ]]; then
            safe_commit "ralph: ${COMPLETED_TASK}" "${SKIP_HOOKS}"
        fi
        last_error_context=""

    elif [[ "${PROMISE_DONE}" == true ]] && [[ "${TASK_MARKED_DONE}" == false ]]; then
        if [[ "${FILES_CHANGED}" == true ]]; then
            print_verdict "partial" "${COMPLETED_TASK}" "${ITER_DURATION}" \
                "claimed done but PRD not marked, files changed"
            log_progress "${iteration}" "${COMPLETED_TASK}" "partial" \
                "Promise + file changes but PRD not marked" "" "${ITER_DURATION}"
            if [[ "${AUTO_COMMIT}" == true ]]; then
                safe_commit "ralph: ${COMPLETED_TASK} (partial)" "${SKIP_HOOKS}"
            fi
        else
            print_verdict "suspicious" "${COMPLETED_TASK}" "${ITER_DURATION}" \
                "claimed done but no file changes and no PRD mark"
            log_progress "${iteration}" "${COMPLETED_TASK}" "suspicious" \
                "Promise without evidence" "${ERROR_TAIL}" "${ITER_DURATION}"
            mark_task_failed "${COMPLETED_TASK}" "${iteration}" "claimed done but no changes"
        fi
        last_error_context="${ERROR_TAIL}"

    elif [[ "${FILES_CHANGED}" == true ]]; then
        print_verdict "incomplete" "${COMPLETED_TASK}" "${ITER_DURATION}" \
            "files changed but no completion signal"
        log_progress "${iteration}" "${COMPLETED_TASK}" "incomplete" \
            "Files changed, no completion signal" "${ERROR_TAIL}" "${ITER_DURATION}"
        last_error_context="${ERROR_TAIL}"

    else
        print_verdict "no-progress" "${COMPLETED_TASK}" "${ITER_DURATION}" \
            "no changes, no completion signal"
        log_progress "${iteration}" "${COMPLETED_TASK}" "no-progress" \
            "No file changes, no signals" "${ERROR_TAIL}" "${ITER_DURATION}"
        mark_task_failed "${COMPLETED_TASK}" "${iteration}" "no progress"
        last_error_context="${ERROR_TAIL}"
    fi

    # ── Post-iteration PRD validation ──
    if [[ -f "${RALPH_PRD}" ]]; then
        local_pending=$(grep -c '^\- \[ \]' "${RALPH_PRD}" 2>/dev/null || echo "0")
        local_done=$(grep -ci '^\- \[x\]' "${RALPH_PRD}" 2>/dev/null || echo "0")
        if [[ "${local_pending}" -eq 0 ]] && [[ "${local_done}" -eq 0 ]]; then
            warn "  PRD appears corrupt (no checkboxes found). Attempting recovery..."
            if git checkout HEAD -- "${RALPH_PRD}" 2>/dev/null; then
                success "  PRD restored from last commit."
            else
                warn "  Could not restore PRD — no previous commit available."
            fi
        fi
    fi

    echo ""
done

warn "Maximum iterations (${MAX_ITERATIONS}) reached."
REMAINING=$(count_pending)
BLOCKED=$(count_blocked)
warn "${REMAINING} tasks pending, ${BLOCKED} blocked. Run again to continue."
print_summary "${iteration}" "${LOOP_START_TIME}" "$(date +%s)"
exit 1
