#!/usr/bin/env bash
# ralph-plan.sh — Takes a rough prompt and generates a structured PRD (task list)
# Usage: ./ralph-plan.sh "Build a REST API with authentication and user management"
#
# Uses a smart model (default: claude-sonnet-4.5) via copilot_here to decompose
# the prompt into atomic, actionable tasks in Markdown format.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${RALPH_PROJECT_DIR:-.}"

# Configuration
PLAN_MODEL="${RALPH_PLAN_MODEL:-claude-sonnet-4.5}"
PRD_FILE="${PROJECT_DIR}/prd.md"
PROGRESS_FILE="${PROJECT_DIR}/progress.md"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    echo "Usage: $0 [OPTIONS] \"<prompt>\""
    echo ""
    echo "Generate a structured PRD from a rough prompt using a smart AI model."
    echo ""
    echo "Options:"
    echo "  -m, --model <model>     Model to use for planning (default: ${PLAN_MODEL})"
    echo "  -o, --output <file>     Output PRD file (default: ./prd.md)"
    echo "  -p, --project <dir>     Project directory (default: current directory)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 \"Build a REST API with user auth\""
    echo "  $0 -m gpt-5 \"Refactor the database layer\""
    echo "  $0 -p ./my-project \"Add caching to all endpoints\""
}

# Parse arguments
PROMPT=""
while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--model) PLAN_MODEL="$2"; shift 2 ;;
        -o|--output) PRD_FILE="$2"; shift 2 ;;
        -p|--project) PROJECT_DIR="$2"; PRD_FILE="${2}/prd.md"; PROGRESS_FILE="${2}/progress.md"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo -e "${RED}Unknown option: $1${NC}"; usage; exit 1 ;;
        *) PROMPT="$1"; shift ;;
    esac
done

if [[ -z "${PROMPT}" ]]; then
    echo -e "${RED}Error: No prompt provided.${NC}"
    usage
    exit 1
fi

# Check if copilot_here is available
if ! command -v copilot_here &>/dev/null && ! command -v copilot_yolo &>/dev/null; then
    echo -e "${RED}Error: copilot_here is not installed.${NC}"
    echo "Install it from: https://github.com/GordonBeeming/copilot_here"
    exit 1
fi

echo -e "${BLUE}=== Ralph Loop Planner ===${NC}"
echo -e "${YELLOW}Model:${NC}   ${PLAN_MODEL}"
echo -e "${YELLOW}Output:${NC}  ${PRD_FILE}"
echo -e "${YELLOW}Prompt:${NC}  ${PROMPT}"
echo ""

# Build the planning prompt
PLAN_PROMPT="$(cat <<'PLAN_TEMPLATE'
You are a senior software architect creating a PRD (Product Requirements Document) for an autonomous AI coding agent.

Your task: Decompose the following user request into a structured, ordered checklist of atomic tasks.

## Rules for task decomposition:

1. Each task must be ATOMIC — completable in a single focused coding session
2. Tasks must be ORDERED — later tasks can depend on earlier ones
3. Each task must have CLEAR acceptance criteria
4. Each task should specify WHICH FILES to create or modify
5. Include setup tasks (dependencies, config) before implementation tasks
6. Include verification tasks (tests, linting) after implementation tasks
7. Label each task with effort: [low], [medium], or [high]
8. Keep tasks small — bias toward more, smaller tasks

## Output format:

Write ONLY a Markdown file with this exact structure:

```
# PRD: <Short Project Title>

> <One-line description of the project>

## Context

<2-3 sentences describing the goal, tech stack, and constraints>

## Tasks

- [ ] **Task 1: <Title>** [effort: low]
  - Description: <What to do>
  - Files: <files to create/modify>
  - Acceptance: <How to verify this is done>

- [ ] **Task 2: <Title>** [effort: medium]
  - Description: <What to do>
  - Files: <files to create/modify>
  - Acceptance: <How to verify this is done>

...continue for all tasks...

## Notes

<Any important architectural decisions, constraints, or warnings>
```

IMPORTANT: Output ONLY the Markdown content. No explanations, no code fences wrapping the whole thing, no preamble.

## User Request:

PLAN_TEMPLATE
)"

FULL_PROMPT="${PLAN_PROMPT}

${PROMPT}"

echo -e "${GREEN}Generating PRD with ${PLAN_MODEL}...${NC}"
echo ""

# Run copilot_here with the smart model to generate the PRD
# Use copilot_yolo for non-interactive execution
PLAN_OUTPUT=$(copilot_yolo --model "${PLAN_MODEL}" --no-pull -p "Read the current project structure and files if any exist, then based on that context, generate a PRD file. Write the PRD directly to the file '${PRD_FILE}'. Here is the planning prompt:

${FULL_PROMPT}" 2>&1) || {
    echo -e "${RED}Error: Planning failed.${NC}"
    echo "${PLAN_OUTPUT}"
    exit 1
}

# Verify the PRD was created
if [[ ! -f "${PRD_FILE}" ]]; then
    echo -e "${YELLOW}PRD file was not created by the agent. Attempting to extract from output...${NC}"
    # Try to extract markdown content from the output
    echo "${PLAN_OUTPUT}" | sed -n '/^# PRD:/,$ p' > "${PRD_FILE}" 2>/dev/null || true

    if [[ ! -s "${PRD_FILE}" ]]; then
        echo -e "${RED}Failed to generate PRD. Raw output:${NC}"
        echo "${PLAN_OUTPUT}"
        exit 1
    fi
fi

# Initialize progress file
if [[ ! -f "${PROGRESS_FILE}" ]]; then
    cat > "${PROGRESS_FILE}" << 'EOF'
# Ralph Loop Progress

## Iteration Log

_No iterations yet._

## Learnings

_No learnings yet._

## Issues

_No issues yet._
EOF
fi

# Count tasks
TASK_COUNT=$(grep -c '^\- \[ \]' "${PRD_FILE}" 2>/dev/null || echo "0")
DONE_COUNT=$(grep -c '^\- \[x\]' "${PRD_FILE}" 2>/dev/null || echo "0")

echo ""
echo -e "${GREEN}=== PRD Generated ===${NC}"
echo -e "${YELLOW}File:${NC}       ${PRD_FILE}"
echo -e "${YELLOW}Tasks:${NC}      ${TASK_COUNT} pending, ${DONE_COUNT} completed"
echo -e "${YELLOW}Progress:${NC}   ${PROGRESS_FILE}"
echo ""
echo -e "${BLUE}Next step:${NC} Review the PRD, then run:"
echo -e "  ${GREEN}./ralph-loop.sh${NC}"
echo ""
echo -e "${YELLOW}Tip:${NC} Edit ${PRD_FILE} to adjust tasks before starting the loop."
