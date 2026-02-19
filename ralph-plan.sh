#!/usr/bin/env bash
# ralph-plan.sh — Takes a rough prompt and generates a structured PRD (task list)
# Usage: ./ralph-plan.sh "Build a REST API with authentication and user management"
#
# Uses a smart model (default: claude-sonnet-4.5) via copilot_yolo to decompose
# the prompt into atomic, actionable tasks in Markdown format.

set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/ralph-lib.sh"

# Configuration
PROJECT_DIR="${RALPH_PROJECT_DIR:-.}"
PLAN_MODEL="${RALPH_PLAN_MODEL:-claude-sonnet-4.5}"

init_ralph_dir "${PROJECT_DIR}"

# ── Usage ─────────────────────────────────────────────────────────

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] "<prompt>"

Generate a structured PRD from a rough prompt using a smart AI model.

Options:
  -m, --model <model>     Model to use for planning (default: ${PLAN_MODEL})
  -p, --project <dir>     Project directory (default: current directory)
  -h, --help              Show this help message

Examples:
  $0 "Build a REST API with user auth"
  $0 -m gpt-5 "Refactor the database layer"
  $0 -p ./my-project "Add caching to all endpoints"
EOF
}

# ── Parse Arguments ───────────────────────────────────────────────

PROMPT=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--model) PLAN_MODEL="$2"; shift 2 ;;
        -p|--project)
            PROJECT_DIR="$2"
            init_ralph_dir "${PROJECT_DIR}"
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) error "Unknown option: $1"; usage; exit 1 ;;
        *) PROMPT="$1"; shift ;;
    esac
done

if [[ -z "${PROMPT}" ]]; then
    error "No prompt provided."
    usage
    exit 1
fi

# Check prerequisites
_ralph_load_copilot
if ! type copilot_yolo &>/dev/null; then
    error "copilot_yolo is not installed."
    echo "Install from: https://github.com/GordonBeeming/copilot_here"
    exit 1
fi

# ── Generate PRD ──────────────────────────────────────────────────

info "=== Ralph Loop Planner ==="
echo -e "${YELLOW}Model:${NC}   ${PLAN_MODEL}"
echo -e "${YELLOW}Output:${NC}  ${RALPH_PRD}"
echo -e "${YELLOW}Prompt:${NC}  ${PROMPT}"
echo ""

PLAN_PROMPT='You are a senior software architect creating a PRD (Product Requirements Document) for an autonomous AI coding agent.

Your task: Decompose the following user request into a structured, ordered checklist of atomic tasks.

## Rules for task decomposition:

1. Each task must be ATOMIC — completable in a single focused coding session (max 15 minutes)
2. Tasks must be ORDERED — later tasks can depend on earlier ones, never the reverse
3. Each task must have MACHINE-VERIFIABLE acceptance criteria (e.g. "npm test passes", "file X exists", "endpoint returns 200")
4. Each task should specify WHICH FILES to create or modify
5. Include setup tasks (dependencies, config) before implementation tasks
6. Include verification tasks (tests, linting) after implementation tasks
7. Label each task with effort: [low], [medium], or [high]
8. Bias toward MORE, SMALLER tasks over fewer, larger ones
9. Never use vague acceptance criteria like "works correctly" or "looks good"

## Output format:

Write ONLY a Markdown file with this exact structure:

# PRD: <Short Project Title>

> <One-line description of the project>

## Context

<2-3 sentences describing the goal, tech stack, and constraints>

## Tasks

- [ ] **Task 1: <Title>** [effort: low]
  - Description: <What to do>
  - Files: <files to create/modify>
  - Acceptance: <Machine-verifiable criterion, e.g. "npm test passes" or "file exists with expected content">

- [ ] **Task 2: <Title>** [effort: medium]
  - Description: <What to do>
  - Files: <files to create/modify>
  - Acceptance: <Machine-verifiable criterion>

...continue for all tasks...

## Notes

<Any important architectural decisions, constraints, or warnings>

IMPORTANT: Output ONLY the Markdown content. No explanations, no code fences wrapping the whole thing, no preamble.

## User Request:

'

FULL_PROMPT="${PLAN_PROMPT}${PROMPT}"

success "Generating PRD with ${PLAN_MODEL}..."
echo ""

# Run copilot_yolo to generate the PRD
PLAN_OUTPUT=$(run_copilot_yolo --model "${PLAN_MODEL}" --no-pull -p "Read the current project structure and files if any exist, then based on that context, generate a PRD file. Write the PRD directly to the file '${RALPH_PRD}'. Here is the planning prompt:

${FULL_PROMPT}" 2>&1) || {
    error "Planning failed."
    echo "${PLAN_OUTPUT}"
    exit 1
}

# Verify the PRD was created
if [[ ! -f "${RALPH_PRD}" ]]; then
    warn "PRD file was not created by the agent. Attempting to extract from output..."
    echo "${PLAN_OUTPUT}" | sed -n '/^# PRD:/,$ p' > "${RALPH_PRD}" 2>/dev/null || true

    if [[ ! -s "${RALPH_PRD}" ]]; then
        error "Failed to generate PRD. Raw output:"
        echo "${PLAN_OUTPUT}"
        exit 1
    fi
fi

# ── Validate PRD ──────────────────────────────────────────────────

echo ""
info "Validating PRD..."
if validate_prd "${RALPH_PRD}"; then
    success "  PRD is valid."
else
    warn "  PRD has issues (see above). You may want to edit it before running the loop."
fi

# ── Initialize State Files ────────────────────────────────────────

init_progress

# Save config snapshot
cat > "${RALPH_CONFIG}" << CONF
# Ralph Loop Configuration (snapshot)
PLAN_MODEL=${PLAN_MODEL}
PLAN_PROMPT=$(echo "${PROMPT}" | head -1)
PLAN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
CONF

# ── Report ────────────────────────────────────────────────────────

TASK_COUNT=$(count_pending)
DONE_COUNT=$(count_done)

echo ""
success "=== PRD Generated ==="
echo -e "${YELLOW}File:${NC}       ${RALPH_PRD}"
echo -e "${YELLOW}Tasks:${NC}      ${TASK_COUNT} pending, ${DONE_COUNT} completed"
echo -e "${YELLOW}Progress:${NC}   ${RALPH_PROGRESS}"
echo ""
info "Next step: Review the PRD, then run:"
echo -e "  ${GREEN}./ralph-loop.sh -p ${PROJECT_DIR}${NC}"
echo ""
dim "Tip: Edit ${RALPH_PRD} to adjust tasks before starting the loop."
