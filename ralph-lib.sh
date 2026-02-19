#!/usr/bin/env bash
# ralph-lib.sh — Shared library for the Ralph Loop
# Source this file from other ralph scripts: source "$(dirname "$0")/ralph-lib.sh"

# ── Colors ────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# ── Print Helpers ─────────────────────────────────────────────────

info()    { echo -e "${BLUE}$*${NC}"; }
success() { echo -e "${GREEN}$*${NC}"; }
warn()    { echo -e "${YELLOW}$*${NC}"; }
error()   { echo -e "${RED}$*${NC}" >&2; }
dim()     { echo -e "${DIM}$*${NC}"; }

# ── .ralph/ Directory Management ──────────────────────────────────

RALPH_DIR=""
RALPH_PRD=""
RALPH_PROGRESS=""
RALPH_FAILED=""
RALPH_CONFIG=""

init_ralph_dir() {
    local project_dir="${1:-.}"
    RALPH_DIR="${project_dir}/.ralph"
    RALPH_PRD="${RALPH_DIR}/prd.md"
    RALPH_PROGRESS="${RALPH_DIR}/progress.md"
    RALPH_FAILED="${RALPH_DIR}/failed-tasks.txt"
    RALPH_CONFIG="${RALPH_DIR}/config.env"

    mkdir -p "${RALPH_DIR}"

    # Ensure .ralph state files are in .gitignore (but NOT prd.md)
    local gitignore="${project_dir}/.gitignore"
    if [[ -f "${gitignore}" ]]; then
        for pattern in ".ralph/progress.md" ".ralph/failed-tasks.txt" ".ralph/config.env"; do
            if ! grep -qF "${pattern}" "${gitignore}" 2>/dev/null; then
                echo "${pattern}" >> "${gitignore}"
            fi
        done
    fi
}

ralph_path() {
    echo "${RALPH_DIR}/${1}"
}

# ── Git Helpers ───────────────────────────────────────────────────

snapshot_git_state() {
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        {
            git diff 2>/dev/null
            git diff --cached 2>/dev/null
            git ls-files --others --exclude-standard 2>/dev/null
        } | shasum -a 256 | cut -d' ' -f1
    else
        echo "no-git"
    fi
}

# Sensitive file patterns to never commit
SENSITIVE_PATTERNS=('.env' '.env.*' '*.pem' '*.key' '*.p12' '*.pfx' '*.secret' '*credential*' '*secret*' 'id_rsa' 'id_ed25519')

safe_commit() {
    local message="$1"
    local skip_hooks="${2:-false}"

    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        warn "Not a git repo — skipping commit"
        return 0
    fi

    # Stage all changes
    git add -A 2>/dev/null || true

    # Unstage sensitive files
    local sensitive_found=false
    for pattern in "${SENSITIVE_PATTERNS[@]}"; do
        if git diff --cached --name-only 2>/dev/null | grep -qiE "(^|/)${pattern}$"; then
            git reset HEAD -- "${pattern}" 2>/dev/null || true
            sensitive_found=true
        fi
    done
    if [[ "${sensitive_found}" == true ]]; then
        warn "  Sensitive files detected and excluded from commit"
    fi

    # Check if there's anything staged
    if git diff --cached --quiet 2>/dev/null; then
        return 0
    fi

    # Commit (respect hooks by default)
    local commit_flags=""
    if [[ "${skip_hooks}" == true ]]; then
        commit_flags="--no-verify"
    fi

    if git commit -m "${message}" ${commit_flags} 2>&1; then
        success "  Committed: ${message}"
    else
        warn "  Commit failed (pre-commit hook?). Changes remain staged."
        return 1
    fi
}

safe_revert() {
    local iteration="$1"
    local reason="${2:-timeout}"

    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        return 0
    fi

    # Stash instead of destroying work
    git add -A 2>/dev/null || true
    if ! git diff --cached --quiet 2>/dev/null || [[ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]]; then
        git stash push -u -m "ralph: partial work iter ${iteration} (${reason})" 2>/dev/null || true
        warn "  Partial work stashed (recoverable via 'git stash list')"
    fi
}

# ── PRD Parsing ───────────────────────────────────────────────────

count_pending() {
    grep -c '^\- \[ \]' "${RALPH_PRD}" 2>/dev/null || echo "0"
}

count_done() {
    grep -c '^\- \[x\]' "${RALPH_PRD}" 2>/dev/null || echo "0"
}

count_blocked() {
    grep -c '^\- \[\~\]' "${RALPH_PRD}" 2>/dev/null || echo "0"
}

detect_completed_task() {
    local newly_done
    newly_done=$(git diff -- "${RALPH_PRD}" 2>/dev/null \
        | grep '^+- \[x\]' \
        | head -1 \
        | sed 's/^+- \[x\] \*\*\(.*\)\*\*.*/\1/' \
        | sed 's/\[effort:.*\]//' \
        | xargs 2>/dev/null) || true
    echo "${newly_done:-unknown task}"
}

list_pending_tasks() {
    grep '^\- \[ \]' "${RALPH_PRD}" 2>/dev/null \
        | sed 's/^- \[ \] \*\*\(.*\)\*\*.*/\1/' \
        | sed 's/\[effort:.*\]//' \
        | xargs -I{} echo "  - {}" 2>/dev/null || true
}

validate_prd() {
    local prd_file="${1:-${RALPH_PRD}}"
    local valid=true

    if [[ ! -f "${prd_file}" ]]; then
        error "PRD file not found: ${prd_file}"
        return 1
    fi

    local task_count
    task_count=$(grep -c '^\- \[ \]' "${prd_file}" 2>/dev/null || echo "0")
    if [[ "${task_count}" -eq 0 ]]; then
        error "PRD has no pending tasks (no '- [ ]' lines found)"
        valid=false
    fi

    # Check for tasks missing key fields
    local tasks_without_acceptance=0
    local in_task=false
    local has_acceptance=false
    while IFS= read -r line; do
        if [[ "${line}" =~ ^-\ \[\ \] ]]; then
            if [[ "${in_task}" == true ]] && [[ "${has_acceptance}" == false ]]; then
                tasks_without_acceptance=$((tasks_without_acceptance + 1))
            fi
            in_task=true
            has_acceptance=false
        elif [[ "${line}" =~ Acceptance: ]]; then
            has_acceptance=true
        fi
    done < "${prd_file}"
    # Check last task
    if [[ "${in_task}" == true ]] && [[ "${has_acceptance}" == false ]]; then
        tasks_without_acceptance=$((tasks_without_acceptance + 1))
    fi

    if [[ "${tasks_without_acceptance}" -gt 0 ]]; then
        warn "  ${tasks_without_acceptance} task(s) missing acceptance criteria"
    fi

    if [[ "${valid}" == false ]]; then
        return 1
    fi

    return 0
}

# ── Progress Logging ──────────────────────────────────────────────

init_progress() {
    if [[ ! -f "${RALPH_PROGRESS}" ]]; then
        cat > "${RALPH_PROGRESS}" << 'EOF'
# Ralph Loop Progress

## Iteration Log

_No iterations yet._
EOF
    fi

    # Initialize failed tasks file
    if [[ ! -f "${RALPH_FAILED}" ]]; then
        echo "# Failed Tasks (tracked automatically)" > "${RALPH_FAILED}"
    fi
}

log_progress() {
    local iteration="$1"
    local task_title="$2"
    local status="$3"
    local notes="${4:-}"
    local error_output="${5:-}"
    local duration="${6:-}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Remove placeholder if present
    if grep -q "^_No iterations yet._$" "${RALPH_PROGRESS}" 2>/dev/null; then
        if [[ "$(uname)" == "Darwin" ]]; then
            sed -i '' 's/^_No iterations yet._$//' "${RALPH_PROGRESS}"
        else
            sed -i 's/^_No iterations yet._$//' "${RALPH_PROGRESS}"
        fi
    fi

    # Append entry
    {
        echo ""
        echo "### Iteration ${iteration} — ${timestamp}"
        echo "- **Task:** ${task_title}"
        echo "- **Status:** ${status}"
        if [[ -n "${duration}" ]]; then
            echo "- **Duration:** ${duration}s"
        fi
        if [[ -n "${notes}" ]]; then
            echo "- **Notes:** ${notes}"
        fi
        if [[ -n "${error_output}" ]]; then
            echo "- **Error context:**"
            echo '```'
            echo "${error_output}"
            echo '```'
        fi
    } >> "${RALPH_PROGRESS}"
}

build_progress_summary() {
    if [[ ! -f "${RALPH_PROGRESS}" ]]; then
        echo "No previous progress."
        return
    fi

    local summary=""

    # Completed tasks (just titles)
    local completed
    completed=$(grep -A1 '^\*\*Status:\*\* completed' "${RALPH_PROGRESS}" 2>/dev/null \
        | grep '^\- \*\*Task:\*\*' \
        | sed 's/- \*\*Task:\*\* //' || true)
    if [[ -n "${completed}" ]]; then
        summary+="Completed tasks:
${completed}

"
    fi

    # Failed/blocked tasks with reasons (important for avoidance)
    local failures
    failures=$(grep -B1 -A3 '^\- \*\*Status:\*\* \(incomplete\|no-progress\|timeout\|suspicious\|blocked\)' "${RALPH_PROGRESS}" 2>/dev/null || true)
    if [[ -n "${failures}" ]]; then
        summary+="Recent failures/issues:
${failures}

"
    fi

    # Last 3 full iteration blocks
    local recent
    recent=$(awk '/^### Iteration /{n++} n>=(NR>0?n-2:1)' "${RALPH_PROGRESS}" 2>/dev/null | tail -30 || true)
    if [[ -n "${recent}" ]]; then
        summary+="Last iterations:
${recent}"
    fi

    if [[ -z "${summary}" ]]; then
        echo "No previous progress."
    else
        echo "${summary}"
    fi
}

# ── Failed Task Tracking ─────────────────────────────────────────

mark_task_failed() {
    local task_title="$1"
    local iteration="$2"
    local reason="${3:-unknown}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "${timestamp} | iter ${iteration} | ${task_title} | ${reason}" >> "${RALPH_FAILED}"
}

get_failed_tasks() {
    if [[ ! -f "${RALPH_FAILED}" ]] || [[ ! -s "${RALPH_FAILED}" ]]; then
        return
    fi

    # Extract unique task titles with their last failure reason
    grep -v '^#' "${RALPH_FAILED}" 2>/dev/null \
        | awk -F' \\| ' '{title=$3; reason=$4; data[title]=reason; iter[title]=$2} END {for (t in data) print "- \"" t "\" — " iter[t] ": " data[t]}' \
        2>/dev/null || true
}

get_failed_task_count() {
    if [[ ! -f "${RALPH_FAILED}" ]]; then
        echo "0"
        return
    fi
    grep -cv '^#' "${RALPH_FAILED}" 2>/dev/null || echo "0"
}

# ── Pre-flight Checks ────────────────────────────────────────────

preflight_check() {
    local project_dir="${1:-.}"
    local errors=0

    info "Running pre-flight checks..."

    # 1. Git repo check
    if ! git -C "${project_dir}" rev-parse --is-inside-work-tree &>/dev/null; then
        warn "  Not a git repository. Auto-commit will be disabled."
    else
        # 2. Dirty working tree check
        if ! git -C "${project_dir}" diff --quiet 2>/dev/null || \
           ! git -C "${project_dir}" diff --cached --quiet 2>/dev/null; then
            warn "  Working tree has uncommitted changes."
            warn "  Consider committing or stashing before running the loop."
        fi
    fi

    # 3. copilot_yolo available
    if ! command -v copilot_yolo &>/dev/null; then
        error "  copilot_yolo not found. Install: https://github.com/GordonBeeming/copilot_here"
        errors=$((errors + 1))
    fi

    # 4. Docker/Podman running
    if command -v docker &>/dev/null; then
        if ! docker info &>/dev/null 2>&1; then
            warn "  Docker is not running. copilot_yolo may fail."
        fi
    elif command -v podman &>/dev/null; then
        if ! podman info &>/dev/null 2>&1; then
            warn "  Podman is not running. copilot_yolo may fail."
        fi
    fi

    # 5. AGENTS.md check
    if [[ ! -f "${project_dir}/AGENTS.md" ]]; then
        warn "  No AGENTS.md found. Consider creating one from AGENTS.md.template."
        warn "  The agent will use generic conventions."
    fi

    if [[ ${errors} -gt 0 ]]; then
        error "Pre-flight failed with ${errors} error(s)."
        return 1
    fi

    success "  Pre-flight checks passed."
    return 0
}

# ── Summary Report ────────────────────────────────────────────────

print_summary() {
    local total_iterations="$1"
    local start_time="$2"
    local end_time="$3"

    local completed
    completed=$(count_done)
    local pending
    pending=$(count_pending)
    local blocked
    blocked=$(count_blocked)
    local total_time=$((end_time - start_time))
    local minutes=$((total_time / 60))
    local seconds=$((total_time % 60))

    local avg_time="n/a"
    if [[ "${completed}" -gt 0 ]]; then
        local avg=$((total_time / completed))
        avg_time="${avg}s"
    fi

    local failed_count
    failed_count=$(get_failed_task_count)

    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║       Ralph Loop — Summary           ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
    echo -e "  Iterations:        ${total_iterations}"
    echo -e "  Tasks completed:   ${GREEN}${completed}${NC}"
    echo -e "  Tasks pending:     ${YELLOW}${pending}${NC}"
    echo -e "  Tasks blocked:     ${RED}${blocked}${NC}"
    echo -e "  Failed attempts:   ${failed_count}"
    echo -e "  Total time:        ${minutes}m ${seconds}s"
    echo -e "  Avg time/task:     ${avg_time}"
    echo -e "  Progress log:      ${RALPH_PROGRESS}"
}
