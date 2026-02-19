#!/usr/bin/env bash
# ralph-lib.sh — Shared library for the Ralph Loop
# Source this file from other ralph scripts: source "$(dirname "$0")/ralph-lib.sh"

# ── Tmpfile Cleanup ──────────────────────────────────────────────

RALPH_TMPFILES=()

ralph_mktemp() {
    local f
    f=$(mktemp)
    RALPH_TMPFILES+=("$f")
    echo "$f"
}

_ralph_cleanup() {
    # Stop output peek if running
    if [[ -n "${RALPH_PEEK_PID:-}" ]]; then
        kill "${RALPH_PEEK_PID}" 2>/dev/null || true
        wait "${RALPH_PEEK_PID}" 2>/dev/null || true
        RALPH_PEEK_PID=""
    fi
    rm -f "${RALPH_TMPFILES[@]}" 2>/dev/null || true
}
trap '_ralph_cleanup' EXIT

# ── Load copilot_here shell functions if not already available ────
# copilot_here.sh uses unbound variables internally, so we must ensure
# nounset is off both when sourcing and when calling its functions.

_ralph_load_copilot() {
    if ! type copilot_yolo &>/dev/null 2>&1; then
        if [[ -f "${HOME}/.copilot_here.sh" ]]; then
            source "${HOME}/.copilot_here.sh"
        fi
    fi
}

# Wrapper that calls copilot_yolo, ensuring a PTY is available
# (copilot_yolo runs Docker which requires a TTY)
run_copilot_yolo() {
    _ralph_load_copilot

    # Prepend container flags (e.g. --playwright) if configured
    local extra_flags=()
    if [[ -n "${RALPH_CONTAINER_FLAGS:-}" ]]; then
        read -ra extra_flags <<< "${RALPH_CONTAINER_FLAGS}"
    fi

    # If we already have a TTY, call directly
    if [[ -t 0 ]]; then
        if [[ -n "${RALPH_OUTPUT_FILE:-}" ]]; then
            copilot_yolo "${extra_flags[@]}" "$@" > "${RALPH_OUTPUT_FILE}" 2>&1
        else
            copilot_yolo "${extra_flags[@]}" "$@"
        fi
        return $?
    fi

    # No TTY available — use 'script' to allocate a PTY
    local argfile
    argfile=$(ralph_mktemp)

    {
        echo '#!/usr/bin/env bash'
        echo 'source ~/.copilot_here.sh 2>/dev/null'
        printf 'copilot_yolo'
        for flag in "${extra_flags[@]}"; do
            printf ' %q' "$flag"
        done
        for arg in "$@"; do
            printf ' %q' "$arg"
        done
        echo ''
    } > "${argfile}"
    chmod +x "${argfile}"

    if [[ -n "${RALPH_OUTPUT_FILE:-}" ]]; then
        # Stream directly to the monitored file (peek loop strips ANSI)
        script -q "${RALPH_OUTPUT_FILE}" bash "${argfile}" >/dev/null 2>&1
        local exit_code=$?
        rm -f "${argfile}"
        return ${exit_code}
    fi

    # Fallback: buffer internally and strip ANSI before emitting
    local outfile
    outfile=$(ralph_mktemp)

    script -q "${outfile}" bash "${argfile}" >/dev/null 2>&1
    local exit_code=$?

    # Output result (strip ANSI escapes and carriage returns)
    sed $'s/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\]0;[^\x07]*\x07//g' "${outfile}" | tr -d '\r'

    rm -f "${argfile}" "${outfile}"
    return ${exit_code}
}

# Portable timeout for copilot_yolo (macOS doesn't have GNU timeout)
# Usage: run_copilot_yolo_with_timeout <seconds> [copilot_yolo args...]
# Returns 124 on timeout (matching GNU timeout behavior)
run_copilot_yolo_with_timeout() {
    local timeout_secs="$1"
    shift

    if [[ -n "${RALPH_OUTPUT_FILE:-}" ]]; then
        # Streaming mode: run_copilot_yolo writes directly to RALPH_OUTPUT_FILE
        run_copilot_yolo "$@" &
        local cmd_pid=$!

        # Watchdog: kill after timeout
        (
            sleep "${timeout_secs}" 2>/dev/null
            kill "${cmd_pid}" 2>/dev/null
        ) &
        local watchdog_pid=$!

        wait "${cmd_pid}" 2>/dev/null
        local exit_code=$?

        # Clean up watchdog
        kill "${watchdog_pid}" 2>/dev/null 2>&1
        wait "${watchdog_pid}" 2>/dev/null 2>&1

        # If killed by signal, return 124 (timeout)
        if [[ ${exit_code} -ge 137 ]]; then
            return 124
        fi
        return ${exit_code}
    fi

    # Non-streaming: buffer internally
    local outfile
    outfile=$(ralph_mktemp)

    run_copilot_yolo "$@" > "${outfile}" 2>&1 &
    local cmd_pid=$!

    # Watchdog: kill after timeout
    (
        sleep "${timeout_secs}" 2>/dev/null
        kill "${cmd_pid}" 2>/dev/null
    ) &
    local watchdog_pid=$!

    wait "${cmd_pid}" 2>/dev/null
    local exit_code=$?

    # Clean up watchdog
    kill "${watchdog_pid}" 2>/dev/null 2>&1
    wait "${watchdog_pid}" 2>/dev/null 2>&1

    # Output captured result
    cat "${outfile}" 2>/dev/null
    rm -f "${outfile}"

    # If killed by signal, return 124 (timeout)
    if [[ ${exit_code} -ge 137 ]]; then
        return 124
    fi
    return ${exit_code}
}

# ── Colors (respects NO_COLOR: https://no-color.org/) ────────────

if [[ -n "${NO_COLOR:-}" ]] || [[ ! -t 1 ]]; then
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' DIM='' BOLD='' MAGENTA='' NC=''
    RALPH_COLOR=false
else
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    DIM='\033[2m'
    BOLD='\033[1m'
    MAGENTA='\033[0;35m'
    NC='\033[0m'
    RALPH_COLOR=true
fi

# Interactive terminal detection (used for output peek)
RALPH_INTERACTIVE=false
if [[ -t 1 ]] && [[ -t 2 ]]; then
    RALPH_INTERACTIVE=true
fi

# ── Print Helpers ─────────────────────────────────────────────────

info()    { echo -e "${BLUE}$*${NC}"; }
success() { echo -e "${GREEN}$*${NC}"; }
warn()    { echo -e "${YELLOW}$*${NC}"; }
error()   { echo -e "${RED}$*${NC}" >&2; }
dim()     { echo -e "${DIM}$*${NC}"; }

# ── Display Functions ────────────────────────────────────────────

format_duration() {
    local secs="$1"
    if [[ "${secs}" -ge 60 ]]; then
        echo "$((secs / 60))m $((secs % 60))s"
    else
        echo "${secs}s"
    fi
}

print_progress_bar() {
    local done="$1"
    local total="$2"
    local width="${3:-24}"

    if [[ "${total}" -eq 0 ]]; then
        echo "  [no tasks]"
        return
    fi

    local pct=$((done * 100 / total))
    local filled=$((done * width / total))
    local empty=$((width - filled))

    # Color based on progress
    local bar_color="${YELLOW}"
    if [[ "${pct}" -ge 75 ]]; then
        bar_color="${GREEN}"
    elif [[ "${pct}" -ge 40 ]]; then
        bar_color="${CYAN}"
    fi

    local bar=""
    local i
    for ((i = 0; i < filled; i++)); do bar+="█"; done
    for ((i = 0; i < empty; i++)); do bar+="░"; done

    echo -e "  ${bar_color}[${bar}]${NC} ${done}/${total} (${pct}%)"
}

get_next_pending_task() {
    local prd_file="${1:-${RALPH_PRD}}"
    local title
    title=$(grep -m1 '^\- \[ \]' "${prd_file}" 2>/dev/null \
        | sed 's/^- \[ \] \*\*\(.*\)\*\*.*/\1/' \
        | sed 's/\[effort:.*\]//' \
        | xargs 2>/dev/null) || true
    # Truncate to ~45 chars
    if [[ ${#title} -gt 45 ]]; then
        title="${title:0:42}..."
    fi
    echo "${title}"
}

print_dashboard() {
    local iteration="$1"
    local model="$2"
    local stagnant_count="$3"
    local done="$4"
    local total="$5"
    local task_name="$6"

    local escalated=""
    if [[ "${model}" != "${LOOP_MODEL:-}" ]] && [[ "${stagnant_count}" -gt 0 ]]; then
        escalated=" ${MAGENTA}[ESCALATED]${NC}"
    fi

    local stag_display=""
    if [[ "${stagnant_count}" -gt 0 ]]; then
        stag_display="  |  ${YELLOW}stagnant: ${stagnant_count}${NC}"
    fi

    echo -e "${CYAN}┌─────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC} ${BOLD}Iteration ${iteration}${NC}  |  ${model}${escalated}${stag_display}"
    echo -e "${CYAN}│${NC}"
    print_progress_bar "${done}" "${total}"
    echo -e "${CYAN}│${NC}"
    if [[ -n "${task_name}" ]]; then
        echo -e "${CYAN}│${NC} Task: ${BOLD}${task_name}${NC}"
    fi
    echo -e "${CYAN}└─────────────────────────────────────────────────────────┘${NC}"
}

print_verdict() {
    local verdict="$1"
    local task_name="$2"
    local duration="$3"
    local detail="${4:-}"

    local icon color label
    case "${verdict}" in
        verified)
            icon="✓" color="${GREEN}" label="VERIFIED" ;;
        completed)
            icon="✓" color="${GREEN}" label="COMPLETED" ;;
        partial)
            icon="◐" color="${YELLOW}" label="PARTIAL" ;;
        timeout)
            icon="⏱" color="${RED}" label="TIMEOUT" ;;
        blocked)
            icon="⊘" color="${RED}" label="BLOCKED" ;;
        suspicious)
            icon="✗" color="${YELLOW}" label="SUSPICIOUS" ;;
        incomplete)
            icon="◐" color="${YELLOW}" label="INCOMPLETE" ;;
        no-progress)
            icon="✗" color="${RED}" label="NO PROGRESS" ;;
        healthcheck-failed)
            icon="⚠" color="${YELLOW}" label="HEALTHCHECK FAILED" ;;
        *)
            icon="?" color="${DIM}" label="${verdict}" ;;
    esac

    echo ""
    echo -e "  ${color}${icon} ${label}: ${task_name}${NC} [$(format_duration "${duration}")]"
    if [[ -n "${detail}" ]]; then
        echo -e "    ${DIM}${detail}${NC}"
    fi
}

# Output peek: shows last few lines of model output in real-time
RALPH_PEEK_PID=""

start_output_peek() {
    local output_file="$1"
    local iter_start="${2:-}"
    local task_timeout="${3:-}"
    local loop_start="${4:-}"

    # Only in interactive terminals with color support
    if [[ "${RALPH_INTERACTIVE}" != true ]] || [[ "${RALPH_COLOR}" != true ]]; then
        return
    fi

    # Number of lines in the live block (elapsed + header + 3 output lines)
    # Line 1: elapsed/timeout status
    # Line 2: spinner + "Agent output:"
    # Lines 3-5: last 3 output lines
    RALPH_PEEK_LINES=5

    # Spinner chars
    (
        local spin_chars='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
        local spin_idx=0
        local prev_lines=""
        local tick=0
        while true; do
            sleep 1
            tick=$((tick + 1))

            local s="${spin_chars:spin_idx:1}"
            spin_idx=$(( (spin_idx + 1) % ${#spin_chars} ))

            # Build elapsed line
            local elapsed_line=""
            if [[ -n "${iter_start}" ]] && [[ -n "${task_timeout}" ]]; then
                local now
                now=$(date +%s)
                local task_elapsed=$((now - iter_start))
                local total_display=""
                if [[ -n "${loop_start}" ]]; then
                    local total_elapsed=$((now - loop_start))
                    total_display="  |  Total: $(format_duration "${total_elapsed}")"
                fi
                elapsed_line="  ${s} $(format_duration "${task_elapsed}") / $(format_duration "${task_timeout}")${total_display}"
            fi

            # Get last 3 non-empty lines from output, strip ANSI
            local lines=""
            if [[ -f "${output_file}" ]]; then
                lines=$(sed $'s/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\]0;[^\x07]*\x07//g' "${output_file}" 2>/dev/null \
                    | grep -v '^$' | tail -3 2>/dev/null) || true
            fi

            # Always redraw (elapsed changes every tick)
            # Move up and clear previous block
            printf "\033[${RALPH_PEEK_LINES}A\033[J" 2>/dev/null || true

            # Line 1: elapsed
            if [[ -n "${elapsed_line}" ]]; then
                echo -e "${elapsed_line}"
            else
                echo ""
            fi

            # Lines 2-5: agent output
            if [[ -n "${lines}" ]]; then
                echo -e "  ${DIM}${s} Agent output:${NC}"
                while IFS= read -r line; do
                    if [[ ${#line} -gt 70 ]]; then
                        line="${line:0:67}..."
                    fi
                    echo -e "    ${DIM}${line}${NC}"
                done <<< "${lines}"
                # Pad to 3 output lines
                local line_count
                line_count=$(echo "${lines}" | wc -l | tr -d ' ')
                local pad=$((3 - line_count))
                while [[ ${pad} -gt 0 ]]; do
                    echo ""
                    pad=$((pad - 1))
                done
            else
                echo -e "  ${DIM}${s} Agent output:${NC}"
                echo -e "    ${DIM}(waiting for output...)${NC}"
                echo ""
                echo ""
            fi
        done
    ) &
    RALPH_PEEK_PID=$!

    # Print placeholder lines that the peek loop will overwrite
    echo -e "  ⠋ 0m 0s / $(format_duration "${task_timeout}")"
    echo -e "  ${DIM}⠋ Agent output:${NC}"
    echo -e "    ${DIM}(waiting for output...)${NC}"
    echo ""
    echo ""
}

stop_output_peek() {
    if [[ -n "${RALPH_PEEK_PID}" ]]; then
        kill "${RALPH_PEEK_PID}" 2>/dev/null || true
        wait "${RALPH_PEEK_PID}" 2>/dev/null || true
        RALPH_PEEK_PID=""
        # Clear peek lines
        if [[ "${RALPH_INTERACTIVE}" == true ]] && [[ "${RALPH_COLOR}" == true ]]; then
            printf "\033[${RALPH_PEEK_LINES:-5}A\033[J" 2>/dev/null || true
        fi
    fi
}

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

    # Add .ralph state files to .gitignore if it already exists
    # (creating .gitignore is the responsibility of PRD Task 1, not Ralph itself)
    local gitignore="${project_dir}/.gitignore"
    if [[ -f "${gitignore}" ]]; then
        for pattern in ".ralph/progress.md" ".ralph/failed-tasks.txt" ".ralph/config.env" ".ralph/debug/" ".ralph/learnings.md"; do
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

# Build artifact patterns to never commit
BUILD_ARTIFACT_PATTERNS=('node_modules' '__pycache__' '.pytest_cache' 'dist' 'build' '.next' 'vendor' 'target' '.venv' 'venv' '*.pyc' '.tox' 'coverage' '.nyc_output' '.gradle' '.DS_Store')

safe_commit() {
    local message="$1"
    local skip_hooks="${2:-false}"

    if ! git rev-parse --is-inside-work-tree &>/dev/null; then
        warn "Not a git repo — skipping commit"
        return 0
    fi

    # Stage all changes
    git add -A 2>/dev/null || true

    # Unstage sensitive files (use -F for literal matching, fixes regex escape bug)
    local sensitive_found=false
    for pattern in "${SENSITIVE_PATTERNS[@]}"; do
        if git diff --cached --name-only 2>/dev/null | grep -qiF "${pattern}"; then
            git reset HEAD -- "${pattern}" 2>/dev/null || true
            sensitive_found=true
        fi
    done
    if [[ "${sensitive_found}" == true ]]; then
        warn "  Sensitive files detected and excluded from commit"
    fi

    # Unstage build artifacts
    local artifacts_found=false
    for pattern in "${BUILD_ARTIFACT_PATTERNS[@]}"; do
        if git diff --cached --name-only 2>/dev/null | grep -qF "/${pattern}" || \
           git diff --cached --name-only 2>/dev/null | grep -qF "${pattern}/"; then
            git reset HEAD -- "*${pattern}*" 2>/dev/null || true
            artifacts_found=true
        fi
    done
    if [[ "${artifacts_found}" == true ]]; then
        warn "  Build artifacts detected and excluded from commit"
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
    local n
    n=$(grep -c '^\- \[ \]' "${RALPH_PRD}" 2>/dev/null) || true
    echo "${n:-0}"
}

count_done() {
    local n
    n=$(grep -ci '^\- \[x\]' "${RALPH_PRD}" 2>/dev/null) || true
    echo "${n:-0}"
}

count_blocked() {
    local n
    n=$(grep -c '^\- \[\~\]' "${RALPH_PRD}" 2>/dev/null) || true
    echo "${n:-0}"
}

detect_completed_task() {
    local newly_done=""

    # Try staged changes first (for commits), then unstaged
    for diff_flag in "--cached" ""; do
        newly_done=$(git diff ${diff_flag} -- "${RALPH_PRD}" 2>/dev/null \
            | grep '^+- \[[xX]\]' \
            | head -1 \
            | sed 's/^+- \[[xX]\] \*\*\(.*\)\*\*.*/\1/' \
            | sed 's/\[effort:.*\]//' \
            | xargs 2>/dev/null) || true
        if [[ -n "${newly_done}" ]]; then
            break
        fi
    done

    # Fallback: if PRD is new (iteration 1), use "initial setup" instead of "unknown task"
    if [[ -z "${newly_done}" ]]; then
        if ! git show HEAD:"${RALPH_PRD}" &>/dev/null 2>&1; then
            echo "initial setup"
        else
            echo "unknown task"
        fi
    else
        echo "${newly_done}"
    fi
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

    # Rotate if progress log exceeds 200 lines
    local line_count
    line_count=$(wc -l < "${RALPH_PROGRESS}" 2>/dev/null || echo "0")
    if [[ "${line_count}" -gt 200 ]]; then
        local archive="${RALPH_DIR}/progress-archive.md"
        local keep_lines=50
        local archive_lines=$((line_count - keep_lines))
        if [[ ${archive_lines} -gt 0 ]]; then
            head -"${archive_lines}" "${RALPH_PROGRESS}" >> "${archive}"
            local tmp
            tmp=$(ralph_mktemp)
            tail -"${keep_lines}" "${RALPH_PROGRESS}" > "${tmp}"
            mv "${tmp}" "${RALPH_PROGRESS}"
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

    # Failed/blocked tasks with reasons (last 3 failures only)
    local failures
    failures=$(grep -B1 -A3 '^\- \*\*Status:\*\* \(incomplete\|no-progress\|timeout\|suspicious\|blocked\)' "${RALPH_PROGRESS}" 2>/dev/null | tail -20 || true)
    if [[ -n "${failures}" ]]; then
        summary+="Recent failures/issues:
${failures}

"
    fi

    # Last 5 full iteration blocks
    local recent
    recent=$(awk '/^### Iteration /{n++} n>=(NR>0?n-4:1)' "${RALPH_PROGRESS}" 2>/dev/null | tail -50 || true)
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
    local category="${4:-no-progress}"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Categories: stagnation, timeout, test-fail, no-progress, blocked, suspicious
    echo "${timestamp} | iter ${iteration} | ${task_title} | ${category} | ${reason}" >> "${RALPH_FAILED}"
}

get_failed_tasks() {
    if [[ ! -f "${RALPH_FAILED}" ]] || [[ ! -s "${RALPH_FAILED}" ]]; then
        return
    fi

    # Extract unique task titles with their last failure category and reason
    # Supports both old 4-field and new 5-field format
    grep -v '^#' "${RALPH_FAILED}" 2>/dev/null \
        | awk -F' \\| ' '{
            title=$3
            if (NF >= 5) { cat=$4; reason=$5 }
            else { cat="unknown"; reason=$4 }
            data[title]=reason; iter[title]=$2; cats[title]=cat
        } END {
            for (t in data) print "- \"" t "\" [" cats[t] "] — " iter[t] ": " data[t]
        }' \
        2>/dev/null || true
}

get_failure_summary() {
    if [[ ! -f "${RALPH_FAILED}" ]] || [[ ! -s "${RALPH_FAILED}" ]]; then
        return
    fi

    # Count failures by category
    grep -v '^#' "${RALPH_FAILED}" 2>/dev/null \
        | awk -F' \\| ' '{
            if (NF >= 5) cat=$4
            else cat="unknown"
            counts[cat]++
        } END {
            for (c in counts) print "  " c ": " counts[c]
        }' \
        2>/dev/null || true
}

get_failed_task_count() {
    if [[ ! -f "${RALPH_FAILED}" ]]; then
        echo "0"
        return
    fi
    local n
    n=$(grep -cv '^#' "${RALPH_FAILED}" 2>/dev/null) || true
    echo "${n:-0}"
}

get_multi_failure_tasks() {
    local min_failures="${1:-2}"
    if [[ ! -f "${RALPH_FAILED}" ]]; then
        return
    fi

    # Find tasks that have failed >= min_failures times and are still pending
    grep -v '^#' "${RALPH_FAILED}" 2>/dev/null \
        | awk -F' \\| ' -v min="${min_failures}" '{
            title=$3; counts[title]++
        } END {
            for (t in counts) if (counts[t] >= min) print "- \"" t "\" (" counts[t] " failures)"
        }' \
        2>/dev/null || true
}

get_task_attempt_count() {
    local title="$1"
    if [[ ! -f "${RALPH_FAILED}" ]]; then
        echo "0"
        return
    fi
    local n
    n=$(grep -cF "| ${title} |" "${RALPH_FAILED}" 2>/dev/null) || true
    echo "${n:-0}"
}

auto_block_task() {
    local title="$1"
    local prd_file="${RALPH_PRD}"

    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/^- \[ \] \*\*${title}\*\*/- [~] **${title}**/" "${prd_file}"
    else
        sed -i "s/^- \[ \] \*\*${title}\*\*/- [~] **${title}**/" "${prd_file}"
    fi

    log_progress "—" "${title}" "auto-blocked" "Exceeded max attempts"
}

# ── Healthcheck ──────────────────────────────────────────────────

parse_verify_commands() {
    local agents_file="$1"
    if [[ ! -f "${agents_file}" ]]; then
        return
    fi

    # Extract commands between ralph:verify:start and ralph:verify:end markers
    local in_block=false
    local in_code=false
    while IFS= read -r line; do
        if [[ "${line}" == *"ralph:verify:start"* ]]; then
            in_block=true
            continue
        fi
        if [[ "${line}" == *"ralph:verify:end"* ]]; then
            break
        fi
        if [[ "${in_block}" == true ]]; then
            # Skip code fence markers
            if [[ "${line}" =~ ^\`\`\` ]]; then
                in_code=$([ "${in_code}" == true ] && echo false || echo true)
                continue
            fi
            # Skip empty lines and comments
            if [[ -z "${line}" ]] || [[ "${line}" =~ ^[[:space:]]*# ]]; then
                continue
            fi
            # Trim leading whitespace and emit
            echo "${line}" | sed 's/^[[:space:]]*//'
        fi
    done < "${agents_file}"
}

run_healthcheck() {
    local project_dir="$1"
    local timeout_secs="${2:-120}"
    local agents_file="${project_dir}/AGENTS.md"

    # Extract verify commands
    local commands
    commands=$(parse_verify_commands "${agents_file}")

    # No verify block — try auto-detection as fallback
    if [[ -z "${commands}" ]]; then
        commands=$(auto_detect_verify_commands "${project_dir}")
        if [[ -z "${commands}" ]]; then
            return 0
        fi
        dim "  Healthcheck: auto-detected verify commands"
    fi

    local healthcheck_output=""
    local failed=false

    while IFS= read -r cmd; do
        # Run each command with a timeout using the portable pattern
        local cmd_output=""
        local cmd_exit=0

        cmd_output=$(cd "${project_dir}" && eval "${cmd}" 2>&1) || cmd_exit=$?

        # Check timeout via background watchdog pattern
        if [[ ${cmd_exit} -ne 0 ]]; then
            healthcheck_output+="FAILED: ${cmd}
${cmd_output}
"
            failed=true
        fi
    done <<< "${commands}"

    if [[ "${failed}" == true ]]; then
        echo "${healthcheck_output}"
        return 1
    fi

    return 0
}

# ── Self-Improving Knowledge Base ─────────────────────────────────

RALPH_LEARNINGS=""

init_learnings() {
    RALPH_LEARNINGS="${RALPH_DIR}/learnings.md"
    if [[ ! -f "${RALPH_LEARNINGS}" ]]; then
        echo "# Ralph Loop Learnings" > "${RALPH_LEARNINGS}"
        echo "" >> "${RALPH_LEARNINGS}"
        echo "_Patterns discovered during task execution._" >> "${RALPH_LEARNINGS}"
    fi
}

append_learning() {
    local task_title="$1"
    local files_changed="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    if [[ -z "${RALPH_LEARNINGS}" ]]; then
        return
    fi

    echo "- [${timestamp}] **${task_title}** — files: ${files_changed}" >> "${RALPH_LEARNINGS}"
}

get_learnings() {
    if [[ -z "${RALPH_LEARNINGS}" ]] || [[ ! -f "${RALPH_LEARNINGS}" ]]; then
        return
    fi

    # Return last 10 learnings (skip header)
    grep '^- \[' "${RALPH_LEARNINGS}" 2>/dev/null | tail -10 || true
}

# ── Output Hash Tracking (stuck-in-loop detection) ───────────────

RALPH_OUTPUT_HASHES=()

compute_output_hash() {
    local output="$1"
    # Strip timestamps, iteration numbers, and ANSI codes to get a content signature
    echo "${output}" \
        | sed 's/[0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}//g' \
        | sed 's/[Ii]teration [0-9]*/iteration N/g' \
        | sed $'s/\x1b\[[0-9;?]*[a-zA-Z]//g' \
        | shasum -a 256 | cut -d' ' -f1
}

track_output_hash() {
    local hash="$1"
    RALPH_OUTPUT_HASHES+=("${hash}")
    # Keep only last 3
    if [[ ${#RALPH_OUTPUT_HASHES[@]} -gt 3 ]]; then
        RALPH_OUTPUT_HASHES=("${RALPH_OUTPUT_HASHES[@]:1}")
    fi
}

detect_repeated_output() {
    if [[ ${#RALPH_OUTPUT_HASHES[@]} -lt 2 ]]; then
        return 1
    fi
    local len=${#RALPH_OUTPUT_HASHES[@]}
    local last="${RALPH_OUTPUT_HASHES[$((len-1))]}"
    local prev="${RALPH_OUTPUT_HASHES[$((len-2))]}"
    if [[ "${last}" == "${prev}" ]]; then
        return 0
    fi
    return 1
}

# ── Checkpoint Tasks ─────────────────────────────────────────────

insert_checkpoint_tasks() {
    local prd_file="$1"
    local interval="${2:-4}"

    # Interval of 0 means no checkpoints
    if [[ "${interval}" -eq 0 ]]; then
        return 0
    fi

    if [[ ! -f "${prd_file}" ]]; then
        return 0
    fi

    # Count total pending tasks
    local total_tasks
    total_tasks=$(grep -c '^\- \[ \]' "${prd_file}" 2>/dev/null || echo "0")

    # Small projects don't need checkpoints
    if [[ "${total_tasks}" -le "${interval}" ]]; then
        return 0
    fi

    local tmp
    tmp=$(ralph_mktemp)
    local task_count=0
    local checkpoint_num=0
    local last_checkpoint_at=0

    while IFS= read -r line; do
        # Detect task headers
        if [[ "${line}" =~ ^-\ \[\ \]\ \*\* ]]; then
            task_count=$((task_count + 1))

            # Insert checkpoint before this task if we've hit the interval
            if [[ $((task_count - last_checkpoint_at - 1)) -ge ${interval} ]]; then
                checkpoint_num=$((checkpoint_num + 1))
                last_checkpoint_at=$((task_count - 1))
                cat >> "${tmp}" <<CKPT

- [ ] **Checkpoint ${checkpoint_num}: Integration Verification** [effort: low]
  - Description: Run full build and test suite. Verify all previously completed features still work. Fix any regressions found before proceeding.
  - Files: (none - verification and regression fixing only)
  - Acceptance: All existing tests pass, application builds successfully, no regressions in completed features

CKPT
            fi
        fi
        echo "${line}" >> "${tmp}"
    done < "${prd_file}"

    # Add final checkpoint if there are remaining tasks after the last checkpoint
    local remaining=$((task_count - last_checkpoint_at))
    if [[ ${remaining} -gt 0 ]] && [[ ${checkpoint_num} -gt 0 || ${task_count} -gt ${interval} ]]; then
        checkpoint_num=$((checkpoint_num + 1))
        cat >> "${tmp}" <<CKPT

- [ ] **Checkpoint ${checkpoint_num}: Final Integration Verification** [effort: low]
  - Description: Run full build and test suite. Verify all previously completed features still work. Fix any regressions found before proceeding.
  - Files: (none - verification and regression fixing only)
  - Acceptance: All existing tests pass, application builds successfully, no regressions in completed features
CKPT
    fi

    mv "${tmp}" "${prd_file}"
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
    _ralph_load_copilot
    if ! type copilot_yolo &>/dev/null; then
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

# ── Efficiency Metrics ─────────────────────────────────────────────

get_iteration_durations() {
    # Extract durations from progress log
    if [[ ! -f "${RALPH_PROGRESS}" ]]; then
        return
    fi
    grep '^\- \*\*Duration:\*\*' "${RALPH_PROGRESS}" 2>/dev/null \
        | sed 's/.*Duration:\*\* \([0-9]*\)s.*/\1/' || true
}

get_slowest_task() {
    if [[ ! -f "${RALPH_PROGRESS}" ]]; then
        return
    fi

    # Find iteration with longest duration
    local max_duration=0
    local max_task=""
    local current_task=""
    while IFS= read -r line; do
        if [[ "${line}" =~ ^\-\ \*\*Task:\*\*\ (.*) ]]; then
            current_task="${BASH_REMATCH[1]}"
        fi
        if [[ "${line}" =~ ^\-\ \*\*Duration:\*\*\ ([0-9]+)s ]]; then
            local dur="${BASH_REMATCH[1]}"
            if [[ ${dur} -gt ${max_duration} ]]; then
                max_duration=${dur}
                max_task="${current_task}"
            fi
        fi
    done < "${RALPH_PROGRESS}"

    if [[ ${max_duration} -gt 0 ]]; then
        echo "${max_task} ($(format_duration "${max_duration}"))"
    fi
}

# ── Auto-detect Verify Commands ──────────────────────────────────

auto_detect_verify_commands() {
    local project_dir="$1"
    local commands=""

    if [[ -f "${project_dir}/package.json" ]]; then
        # Node.js project
        if grep -q '"test"' "${project_dir}/package.json" 2>/dev/null; then
            commands+="npm test"$'\n'
        fi
        if grep -q '"build"' "${project_dir}/package.json" 2>/dev/null; then
            commands+="npm run build"$'\n'
        fi
        if grep -q '"lint"' "${project_dir}/package.json" 2>/dev/null; then
            commands+="npm run lint"$'\n'
        fi
    elif [[ -f "${project_dir}/requirements.txt" ]] || [[ -f "${project_dir}/pyproject.toml" ]] || [[ -f "${project_dir}/setup.py" ]]; then
        # Python project
        if [[ -f "${project_dir}/pytest.ini" ]] || [[ -f "${project_dir}/pyproject.toml" ]] || [[ -d "${project_dir}/tests" ]]; then
            commands+="python -m pytest"$'\n'
        fi
        if [[ -f "${project_dir}/pyproject.toml" ]] && grep -q 'ruff' "${project_dir}/pyproject.toml" 2>/dev/null; then
            commands+="ruff check ."$'\n'
        fi
    elif [[ -f "${project_dir}/go.mod" ]]; then
        commands+="go build ./..."$'\n'
        commands+="go test ./..."$'\n'
    elif [[ -f "${project_dir}/Cargo.toml" ]]; then
        commands+="cargo build"$'\n'
        commands+="cargo test"$'\n'
    fi

    echo "${commands}"
}

# ── QA Agent Functions ───────────────────────────────────────────

build_qa_prompt() {
    cat <<'QA_PROMPT'
You are an independent QA agent. Your job is to TEST — not implement, not fix.

## Your Mission

1. Read .ralph/prd.md and identify all tasks marked [x] (completed)
2. For EACH completed task, verify it actually works by testing the acceptance criteria
3. Use the appropriate tool for each test:
   - File/config tasks → check file exists, has expected content (bash, cat, jq)
   - API endpoints → start the server, test with curl (check status codes, response shapes)
   - UI features → start the server, use Playwright to navigate and verify
   - Build/test tasks → run the commands and check they pass
4. Report your findings

## Testing Approach

- Start the dev server if any task involves API or UI
- For API tests: use curl with -sf flag, check response codes and JSON shape
- For UI tests: use Playwright to navigate, check elements exist, forms work
- For file tests: check existence, content, valid syntax
- Test FUNCTIONALITY, not just existence — click buttons, submit forms, call endpoints
- Be THOROUGH but FAIR — test what the acceptance criteria ask for

## Output Format

For EACH completed task, output exactly one line:

<ralph>QA task="Task Title" status="pass"</ralph>
or
<ralph>QA task="Task Title" status="fail" reason="Description of what doesn't work"</ralph>

At the end, output a summary:
<ralph>QA_DONE passed=N failed=M</ralph>

## Rules

- Do NOT modify any project files
- Do NOT fix any bugs you find
- Do NOT mark/unmark tasks in the PRD
- ONLY test and report
- If you can't test a task (e.g., no server setup yet), mark it as pass
- If the dev server fails to start, that's a fail for ALL server-dependent tasks
QA_PROMPT
}

run_qa_agent() {
    local project_dir="$1"
    local timeout="${2:-300}"

    local qa_prompt
    qa_prompt=$(build_qa_prompt)

    local output
    output=$(run_copilot_yolo_with_timeout "${timeout}" \
        --model "${LOOP_MODEL:-gpt-4.1}" --no-pull \
        -p "${qa_prompt}") || true

    echo "${output}"
}

parse_qa_results() {
    local qa_output="$1"

    # Extract QA result lines
    local results
    results=$(echo "${qa_output}" | grep '<ralph>QA ' || true)

    if [[ -z "${results}" ]]; then
        echo "QA_PARSE_ERROR"
        return 1
    fi

    # Parse each result
    local passed=0 failed=0
    local failed_tasks=""

    while IFS= read -r line; do
        local task status reason
        task=$(echo "${line}" | sed -n 's/.*task="\([^"]*\)".*/\1/p')
        status=$(echo "${line}" | sed -n 's/.*status="\([^"]*\)".*/\1/p')
        reason=$(echo "${line}" | sed -n 's/.*reason="\([^"]*\)".*/\1/p')

        if [[ "${status}" == "pass" ]]; then
            passed=$((passed + 1))
        elif [[ "${status}" == "fail" ]]; then
            failed=$((failed + 1))
            failed_tasks+="${task}|${reason}"$'\n'
        fi
    done <<< "${results}"

    echo "QA_PASSED=${passed}"
    echo "QA_FAILED=${failed}"
    if [[ -n "${failed_tasks}" ]]; then
        echo "QA_FAILURES:"
        echo -n "${failed_tasks}"
    fi

    [[ ${failed} -eq 0 ]]
}

uncheck_task() {
    local task_title="$1"
    local escaped
    escaped=$(printf '%s\n' "${task_title}" | sed 's/[[\.*^$()+?{|]/\\&/g')
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "s/^\(- \)\[[xX]\]\(.*${escaped}.*\)/\1[ ]\2/" "${RALPH_PRD}"
    else
        sed -i "s/^\(- \)\[[xX]\]\(.*${escaped}.*\)/\1[ ]\2/" "${RALPH_PRD}"
    fi
}

annotate_task_failure() {
    local task_title="$1"
    local reason="$2"
    local escaped
    escaped=$(printf '%s\n' "${task_title}" | sed 's/[[\.*^$()+?{|]/\\&/g')

    # Find the task line number
    local line_num
    line_num=$(grep -n "${escaped}" "${RALPH_PRD}" | head -1 | cut -d: -f1)

    if [[ -n "${line_num}" ]]; then
        # Find the Acceptance: line for this task (within next 5 lines)
        local acc_line
        acc_line=$(sed -n "$((line_num+1)),$((line_num+5))p" "${RALPH_PRD}" | grep -n 'Acceptance:' | head -1 | cut -d: -f1)

        if [[ -n "${acc_line}" ]]; then
            local insert_at=$((line_num + acc_line))
            if [[ "$(uname)" == "Darwin" ]]; then
                sed -i '' "${insert_at}a\\
  - QA-Failure: ${reason}" "${RALPH_PRD}"
            else
                sed -i "${insert_at}a\\
  - QA-Failure: ${reason}" "${RALPH_PRD}"
            fi
        fi
    fi
}

extract_task_files() {
    local task_title="$1"
    local prd_file="${2:-${RALPH_PRD}}"
    local escaped
    escaped=$(printf '%s\n' "${task_title}" | sed 's/[[\.*^$()+?{|]/\\&/g')

    # Find the task line number
    local line_num
    line_num=$(grep -n "${escaped}" "${prd_file}" | head -1 | cut -d: -f1)

    if [[ -n "${line_num}" ]]; then
        # Look for Files: line within next 5 lines
        sed -n "$((line_num+1)),$((line_num+5))p" "${prd_file}" \
            | grep 'Files:' | head -1 \
            | sed 's/.*Files: *//' \
            | tr ',' '\n' \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
            | grep -v '^(none' || true
    fi
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

    local avg_time="n/a"
    if [[ "${completed}" -gt 0 ]]; then
        local avg=$((total_time / completed))
        avg_time="$(format_duration "${avg}")"
    fi

    local failed_count
    failed_count=$(get_failed_task_count)

    local total_tasks=$((completed + pending + blocked))

    # Banner color based on outcome
    local banner_color="${YELLOW}"
    if [[ "${pending}" -eq 0 ]] && [[ "${blocked}" -eq 0 ]]; then
        banner_color="${GREEN}"
    elif [[ "${completed}" -eq 0 ]]; then
        banner_color="${RED}"
    fi

    echo ""
    echo -e "${banner_color}╔══════════════════════════════════════╗${NC}"
    echo -e "${banner_color}║       Ralph Loop — Summary           ║${NC}"
    echo -e "${banner_color}╚══════════════════════════════════════╝${NC}"
    echo ""
    print_progress_bar "${completed}" "${total_tasks}"
    echo ""
    echo -e "  ${GREEN}Completed:${NC}  ${completed}    ${YELLOW}Pending:${NC} ${pending}    ${RED}Blocked:${NC} ${blocked}    ${DIM}Failed:${NC} ${failed_count}"
    echo -e "  Iterations: ${total_iterations}  |  Duration: $(format_duration "${total_time}")  |  Avg/task: ${avg_time}"

    # Efficiency metrics
    local avg_iter_time="n/a"
    if [[ "${total_iterations}" -gt 0 ]]; then
        local avg_iter=$((total_time / total_iterations))
        avg_iter_time="$(format_duration "${avg_iter}")"
    fi
    local slowest
    slowest=$(get_slowest_task)
    echo -e "  Avg/iteration: ${avg_iter_time}"
    if [[ -n "${slowest}" ]]; then
        echo -e "  Slowest task: ${slowest}"
    fi
    echo ""

    # Failure category breakdown
    local failure_breakdown
    failure_breakdown=$(get_failure_summary)
    if [[ -n "${failure_breakdown}" ]]; then
        echo -e "  ${RED}Failure breakdown:${NC}"
        echo "${failure_breakdown}"
        echo ""
    fi

    # List completed tasks
    local done_tasks
    done_tasks=$(grep -i '^\- \[x\]' "${RALPH_PRD}" 2>/dev/null \
        | sed 's/^- \[[xX]\] \*\*\(.*\)\*\*.*/\1/' \
        | sed 's/\[effort:.*\]//' || true)
    if [[ -n "${done_tasks}" ]]; then
        echo -e "  ${GREEN}Completed:${NC}"
        while IFS= read -r t; do
            t=$(echo "${t}" | xargs 2>/dev/null)
            echo -e "    ${GREEN}✓${NC} ${t}"
        done <<< "${done_tasks}"
    fi

    # List pending tasks
    local open_tasks
    open_tasks=$(grep '^\- \[ \]' "${RALPH_PRD}" 2>/dev/null \
        | sed 's/^- \[ \] \*\*\(.*\)\*\*.*/\1/' \
        | sed 's/\[effort:.*\]//' || true)
    if [[ -n "${open_tasks}" ]]; then
        echo -e "  ${YELLOW}Remaining:${NC}"
        while IFS= read -r t; do
            t=$(echo "${t}" | xargs 2>/dev/null)
            echo -e "    ${DIM}○${NC} ${t}"
        done <<< "${open_tasks}"
    fi

    echo ""
    echo -e "  ${DIM}Progress log: ${RALPH_PROGRESS}${NC}"
}
