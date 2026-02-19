#!/usr/bin/env bash
# ralph.sh — One-command Ralph Loop: plan + execute
# Usage: ./ralph.sh "Build a REST API with authentication"
#
# This is the main entry point that combines planning and execution:
# 1. Generates a PRD from your prompt using a smart model
# 2. Lets you review/edit the PRD
# 3. Runs the Ralph Loop with a cheap model to complete all tasks

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ralph-lib.sh"

# Configuration (override via environment variables)
RALPH_PLAN_MODEL="${RALPH_PLAN_MODEL:-claude-sonnet-4.5}"
RALPH_LOOP_MODEL="${RALPH_LOOP_MODEL:-gpt-4.1}"
RALPH_PROJECT_DIR="${RALPH_PROJECT_DIR:-.}"
RALPH_MAX_ITERATIONS="${RALPH_MAX_ITERATIONS:-50}"
RALPH_AUTO_COMMIT="${RALPH_AUTO_COMMIT:-true}"
RALPH_SKIP_REVIEW="${RALPH_SKIP_REVIEW:-false}"
RALPH_SKIP_HOOKS="${RALPH_SKIP_HOOKS:-false}"
RALPH_TWO_PHASE="${RALPH_TWO_PHASE:-false}"

# ── Usage ─────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] "<prompt>"

One-command Ralph Loop: generate a task list and execute it autonomously.

Options:
  --plan-model <model>      Model for planning (default: ${RALPH_PLAN_MODEL})
  --loop-model <model>      Model for execution (default: ${RALPH_LOOP_MODEL})
  -p, --project <dir>       Project directory (default: current directory)
  -n, --max-iterations <n>  Max loop iterations (default: ${RALPH_MAX_ITERATIONS})
  --no-commit               Don't auto-commit after each task
  --skip-review             Skip PRD review step (fully autonomous)
  --skip-hooks              Skip git pre-commit hooks
  --two-phase               Use two-phase execution (select + implement)
  --plan-only               Only generate the PRD, don't execute
  --loop-only               Only run the loop (PRD must already exist)
  -h, --help                Show this help message

Environment variables:
  RALPH_PLAN_MODEL          Planning model (default: claude-sonnet-4.5)
  RALPH_LOOP_MODEL          Execution model (default: gpt-4.1)
  RALPH_PROJECT_DIR         Project directory (default: .)
  RALPH_MAX_ITERATIONS      Max loop iterations (default: 50)
  RALPH_AUTO_COMMIT         Auto-commit after tasks (default: true)
  RALPH_SKIP_HOOKS          Skip pre-commit hooks (default: false)
  RALPH_TWO_PHASE           Two-phase execution (default: false)

Examples:
  $0 "Build a CLI tool for managing TODO lists"
  $0 --plan-model gpt-5 --loop-model gpt-4.1 "Add user auth to the API"
  $0 --plan-only "Refactor the database layer"
  $0 --loop-only
  $0 --skip-review "Quick script to process CSV files"
  $0 --two-phase "Complex multi-service architecture"
EOF
}

# ── Parse Arguments ───────────────────────────────────────────────

PROMPT=""
PLAN_ONLY=false
LOOP_ONLY=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --plan-model) RALPH_PLAN_MODEL="$2"; shift 2 ;;
        --loop-model) RALPH_LOOP_MODEL="$2"; shift 2 ;;
        -p|--project) RALPH_PROJECT_DIR="$2"; shift 2 ;;
        -n|--max-iterations) RALPH_MAX_ITERATIONS="$2"; shift 2 ;;
        --no-commit) RALPH_AUTO_COMMIT=false; shift ;;
        --skip-review) RALPH_SKIP_REVIEW=true; shift ;;
        --skip-hooks) RALPH_SKIP_HOOKS=true; shift ;;
        --two-phase) RALPH_TWO_PHASE=true; shift ;;
        --plan-only) PLAN_ONLY=true; shift ;;
        --loop-only) LOOP_ONLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) error "Unknown option: $1"; usage; exit 1 ;;
        *) PROMPT="$1"; shift ;;
    esac
done

# Validate
if [[ "${LOOP_ONLY}" == false ]] && [[ -z "${PROMPT}" ]]; then
    error "No prompt provided."
    usage
    exit 1
fi

# Export for sub-scripts
export RALPH_PROJECT_DIR
export RALPH_PLAN_MODEL
export RALPH_LOOP_MODEL
export RALPH_MAX_ITERATIONS
export RALPH_AUTO_COMMIT
export RALPH_SKIP_HOOKS
export RALPH_TWO_PHASE

init_ralph_dir "${RALPH_PROJECT_DIR}"

# ── Banner ────────────────────────────────────────────────────────

echo -e "${BLUE}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          Ralph Loop — Autonomous Agent       ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Plan model:${NC}  ${RALPH_PLAN_MODEL}"
echo -e "${YELLOW}Loop model:${NC}  ${RALPH_LOOP_MODEL}"
echo -e "${YELLOW}Project:${NC}     ${RALPH_PROJECT_DIR}"
echo -e "${YELLOW}State dir:${NC}   .ralph/"
echo ""

# ── Pre-flight Checks ────────────────────────────────────────────

preflight_check "${RALPH_PROJECT_DIR}" || {
    error "Pre-flight checks failed. Fix the issues above before continuing."
    exit 1
}
export RALPH_PREFLIGHT_DONE=1
echo ""

# ── Phase 1: Planning ────────────────────────────────────────────

if [[ "${LOOP_ONLY}" == false ]]; then
    echo -e "${CYAN}━━━ Phase 1: Planning ━━━${NC}"
    echo ""

    "${SCRIPT_DIR}/ralph-plan.sh" \
        -m "${RALPH_PLAN_MODEL}" \
        -p "${RALPH_PROJECT_DIR}" \
        "${PROMPT}"

    if [[ "${PLAN_ONLY}" == true ]]; then
        success "Plan generated. Review ${RALPH_PRD} and run:"
        echo -e "  ${GREEN}$0 --loop-only -p ${RALPH_PROJECT_DIR}${NC}"
        exit 0
    fi

    # Review step
    if [[ "${RALPH_SKIP_REVIEW}" == false ]]; then
        echo ""
        echo -e "${YELLOW}━━━ PRD Review ━━━${NC}"
        echo ""
        echo -e "The PRD has been generated at: ${BLUE}${RALPH_PRD}${NC}"
        echo ""
        echo "Please review it now. You can:"
        echo "  - Edit tasks, reorder them, remove or add items"
        echo "  - Adjust effort labels or acceptance criteria"
        echo "  - Add notes or constraints"
        echo ""
        read -p "Press ENTER to start the loop, or Ctrl+C to abort... " _
    fi
fi

# ── Phase 2: Execution Loop ──────────────────────────────────────

if [[ ! -f "${RALPH_PRD}" ]]; then
    error "PRD file not found at ${RALPH_PRD}"
    echo "Run with a prompt first, or use --plan-only to generate it."
    exit 1
fi

echo ""
echo -e "${CYAN}━━━ Phase 2: Execution Loop ━━━${NC}"
echo ""

LOOP_ARGS=(-m "${RALPH_LOOP_MODEL}" -p "${RALPH_PROJECT_DIR}" -n "${RALPH_MAX_ITERATIONS}")
[[ "${RALPH_AUTO_COMMIT}" == false ]] && LOOP_ARGS+=(--no-commit)
[[ "${RALPH_SKIP_HOOKS}" == true ]] && LOOP_ARGS+=(--skip-hooks)
[[ "${RALPH_TWO_PHASE}" == true ]] && LOOP_ARGS+=(--two-phase)

"${SCRIPT_DIR}/ralph-loop.sh" "${LOOP_ARGS[@]}"

LOOP_EXIT=$?

echo ""
if [[ ${LOOP_EXIT} -eq 0 ]]; then
    success "Ralph Loop finished successfully."
else
    warn "Ralph Loop exited with code ${LOOP_EXIT}."
fi
echo -e "PRD:      ${RALPH_PRD}"
echo -e "Progress: ${RALPH_PROGRESS}"
echo -e "Failures: ${RALPH_FAILED}"

exit ${LOOP_EXIT}
