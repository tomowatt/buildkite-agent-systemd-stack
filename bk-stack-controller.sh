#!/usr/bin/env bash
# =============================================================================
# bk-stack-controller.sh — Buildkite Stack Controller Daemon
#
# A systemd-managed service that polls the Buildkite Stacks API for scheduled
# jobs and spawns isolated transient systemd units (one per job) to run them.
#
# USAGE
#   Run as a systemd service (see bk-stack-controller.service).
#   Do not invoke directly in production.
#
# ENVIRONMENT (via EnvironmentFile or systemd drop-in)
#   Required:
#     BK_AGENT_TOKEN          Buildkite cluster agent token
#     BK_STACK_KEY            Unique identifier for this stack instance
#     BK_AGENTAPI_BASE_URL    Base URL for the Agent API
#                             e.g. https://agent.buildkite.com/v3
#
#   Optional:
#     BK_QUEUE                Agent queue name (default: default)
#     BK_MAX_AGENTS           Maximum concurrent agents (default: 4)
#     BK_POLL_INTERVAL        Seconds between polls (default: 5)
#     BK_JOB_TIMEOUT          Max seconds a job unit may run (default: 3600)
#     BK_GIT_MIRRORS_PATH     Shared git mirrors directory
#     BK_CACHE_PATH           Shared dependency cache directory
#     BK_SSH_AGENT_SOCK       Path to shared ssh-agent socket (optional)
#     BK_CREDENTIAL_SSH_KEY   Path to SSH key for LoadCredential (optional)
#     BK_AGENT_TOKEN_FILE     Path to file containing the agent token, injected
#                             into each job unit via LoadCredential. The token
#                             is never placed on the command line.
#                             (default: /etc/bk-stack/secrets/agent-token)
#     BK_EXTRA_ENV_FILE       Path to additional EnvironmentFile for agents
#     BK_WORK_DIR             Scratch directory for agent workspaces
#                             (default: /var/lib/bk-stack/work)
#     BK_LOG_LEVEL            debug | info | warn | error (default: info)
# =============================================================================

set -euo pipefail

# =============================================================================
# Defaults
# =============================================================================

BK_QUEUE="${BK_QUEUE:-default}"
BK_MAX_AGENTS="${BK_MAX_AGENTS:-4}"
BK_POLL_INTERVAL="${BK_POLL_INTERVAL:-5}"
BK_JOB_TIMEOUT="${BK_JOB_TIMEOUT:-3600}"
BK_WORK_DIR="${BK_WORK_DIR:-/var/lib/bk-stack/work}"
BK_LOG_LEVEL="${BK_LOG_LEVEL:-info}"
BK_AGENT_TOKEN_FILE="${BK_AGENT_TOKEN_FILE:-/etc/bk-stack/secrets/agent-token}"

# Internal state
STACK_REGISTERED=0
SHUTDOWN_REQUESTED=0

# =============================================================================
# Logging
# =============================================================================

log() {
    local level="$1"; shift
    local levels="debug info warn error"
    local level_val log_val

    # Numeric rank for each level
    level_val=$(echo "$levels" | tr ' ' '\n' | grep -n "^${level}$" | cut -d: -f1)
    log_val=$(echo "$levels"   | tr ' ' '\n' | grep -n "^${BK_LOG_LEVEL}$" | cut -d: -f1)

    [[ "${level_val:-0}" -lt "${log_val:-2}" ]] && return 0

    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    printf '%s [%-5s] %s\n' "$ts" "${level^^}" "$*" >&2
}

log_debug() { log debug "$@"; }
log_info()  { log info  "$@"; }
log_warn()  { log warn  "$@"; }
log_error() { log error "$@"; }

die() {
    log_error "$@"
    exit 1
}

# =============================================================================
# Prerequisite checks
# =============================================================================

check_prerequisites() {
    local missing=()
    for cmd in curl jq systemd-run systemctl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] || die "Missing required commands: ${missing[*]}"

    [[ -n "${BK_AGENT_TOKEN:-}"       ]] || die "BK_AGENT_TOKEN is not set"
    [[ -n "${BK_STACK_KEY:-}"         ]] || die "BK_STACK_KEY is not set"
    [[ -n "${BK_AGENTAPI_BASE_URL:-}" ]] || die "BK_AGENTAPI_BASE_URL is not set"
    # BK_AGENT_TOKEN_FILE is read by systemd (as root) via LoadCredential when
    # spawning agent units — the controller process itself never reads it, so we
    # only check the variable is set, not that the file is accessible here.
    [[ -n "${BK_AGENT_TOKEN_FILE:-}"  ]] || die "BK_AGENT_TOKEN_FILE is not set"

    mkdir -p "$BK_WORK_DIR"
    log_info "Prerequisites OK"
}

# =============================================================================
# Stacks API helpers
# =============================================================================

# All Agent API calls share this base invocation.
# Usage: api_call <method> <path> [curl-extra-args...]
api_call() {
    local method="$1" path="$2"; shift 2
    local url="${BK_AGENTAPI_BASE_URL}${path}"

    log_debug "API ${method} ${url}"

    curl --silent --fail-with-body \
        --max-time 30 \
        -X "$method" \
        -H "Authorization: Token token=\"${BK_AGENT_TOKEN}\"" \
        -H "Content-Type: application/json" \
        "$@" \
        "$url"
}

# Register this stack with the Buildkite cluster queue.
# The API is idempotent — safe to call on every startup.
register_stack() {
    log_info "Registering stack '${BK_STACK_KEY}' on queue '${BK_QUEUE}'"

    local payload
    payload=$(jq -n \
        --arg key  "$BK_STACK_KEY" \
        --arg queue "$BK_QUEUE" \
        '{ stack_key: $key, queue: $queue }')

    local response
    response=$(api_call POST "/stacks/register" --data "$payload") \
        || die "Failed to register stack. API response: ${response:-<empty>}"

    STACK_REGISTERED=1
    log_info "Stack registered"
}

# Fetch pending scheduled jobs for this stack.
# Returns raw JSON array.
get_scheduled_jobs() {
    api_call GET "/stacks/${BK_STACK_KEY}/scheduled-jobs" 2>/dev/null || echo "[]"
}

# Atomically reserve a job so no other stack instance claims it.
# Usage: reserve_job <job_uuid>
# Returns 0 on success, 1 if the job was already taken.
reserve_job() {
    local job_uuid="$1"
    local payload
    payload=$(jq -n --arg id "$job_uuid" '{ job_id: $id }')

    local http_code
    http_code=$(curl --silent --output /dev/null --write-out "%{http_code}" \
        --max-time 15 \
        -X POST \
        -H "Authorization: Token token=\"${BK_AGENT_TOKEN}\"" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        "${BK_AGENTAPI_BASE_URL}/stacks/${BK_STACK_KEY}/reserve-jobs")

    if [[ "$http_code" == "200" ]]; then
        log_debug "Reserved job ${job_uuid}"
        return 0
    else
        log_debug "Job ${job_uuid} already reserved (HTTP ${http_code})"
        return 1
    fi
}

# Send a status notification back to the Buildkite build page.
# Usage: notify_job <job_uuid> <message>
notify_job() {
    local job_uuid="$1" message="$2"
    local payload
    payload=$(jq -n --arg msg "$message" '{ message: $msg }')

    api_call POST "/stacks/${BK_STACK_KEY}/jobs/${job_uuid}/notifications" \
        --data "$payload" > /dev/null 2>&1 || true  # non-fatal
}

# Check if dispatch is paused for this stack's queue.
# Returns 0 (paused) or 1 (not paused).
dispatch_paused() {
    local result
    result=$(api_call GET "/stacks/${BK_STACK_KEY}" 2>/dev/null \
        | jq -r '.cluster_queue.dispatch_paused // false')
    [[ "$result" == "true" ]]
}

# =============================================================================
# Agent unit management
# =============================================================================

# Return the systemd unit name for a given job UUID.
unit_name() {
    echo "bk-agent-${1}.service"
}

# Count currently running agent units.
running_agent_count() {
    systemctl list-units --no-legend --state=active,activating 'bk-agent-*.service' \
        | wc -l
}

# Build the systemd-run invocation for a single job, then execute it.
# Usage: spawn_agent <job_uuid> <agent_query_rules_json>
spawn_agent() {
    local job_uuid="$1"
    local query_rules="$2"
    local unit
    unit=$(unit_name "$job_uuid")
    local work_dir="${BK_WORK_DIR}/${job_uuid}"

    mkdir -p "$work_dir"

    log_info "Spawning agent unit ${unit}"
    notify_job "$job_uuid" "Provisioning systemd agent unit"

    # ------------------------------------------------------------------
    # Build systemd-run arguments array.
    # We construct this as a proper array to avoid quoting pitfalls.
    # ------------------------------------------------------------------
    local args=(
        systemd-run
        --unit="$unit"
        --description="Buildkite agent for job ${job_uuid}"

        # --- Isolation ----------------------------------------------------
        --property="DynamicUser=yes"
        --property="PrivateTmp=yes"
        --property="PrivateDevices=yes"
        --property="ProtectHome=yes"
        --property="NoNewPrivileges=yes"

        # --- Resource limits ---------------------------------------------
        --property="MemoryMax=4G"
        --property="CPUQuota=200%"
        --property="TasksMax=512"

        # Watchdog: abort the unit if it runs over the job timeout
        --property="RuntimeMaxSec=${BK_JOB_TIMEOUT}"

        # --- Working directory -------------------------------------------
        --property="WorkingDirectory=${work_dir}"
        --property="Environment=BUILDKITE_BUILD_PATH=${work_dir}"

        # --- Agent token & job targeting ---------------------------------
        # Token injected via LoadCredential (file reference, never on the
        # command line) so it is NOT visible via `systemctl show` or /proc.
        --property="LoadCredential=agent-token:${BK_AGENT_TOKEN_FILE}"
        --property="Environment=BUILDKITE_AGENT_ACQUIRE_JOB=${job_uuid}"

        # Queue name is non-sensitive; passed as env so the shell wrapper below
        # can forward it to buildkite-agent without hardcoding it in the args.
        --property="Environment=_BK_QUEUE=${BK_QUEUE}"
    )

    # --- Shared git mirrors (read-write so agent can update the mirror) --
    if [[ -n "${BK_GIT_MIRRORS_PATH:-}" ]]; then
        args+=(--property="BindPaths=${BK_GIT_MIRRORS_PATH}")
        args+=(--property="Environment=BUILDKITE_GIT_MIRRORS_PATH=${BK_GIT_MIRRORS_PATH}")
    fi

    # --- Shared dependency cache (read-only; cache population via hooks) -
    if [[ -n "${BK_CACHE_PATH:-}" ]]; then
        args+=(--property="BindReadOnlyPaths=${BK_CACHE_PATH}")
    fi

    # --- SSH: prefer LoadCredential (key material, strongest isolation) --
    if [[ -n "${BK_CREDENTIAL_SSH_KEY:-}" ]]; then
        args+=(--property="LoadCredential=ssh-key:${BK_CREDENTIAL_SSH_KEY}")
        # The environment hook in the agent will call ssh-add from $CREDENTIALS_DIRECTORY
    # --- SSH: fall back to shared ssh-agent socket -----------------------
    elif [[ -n "${BK_SSH_AGENT_SOCK:-}" ]]; then
        args+=(--property="BindReadOnlyPaths=${BK_SSH_AGENT_SOCK}")
        args+=(--property="Environment=SSH_AUTH_SOCK=${BK_SSH_AGENT_SOCK}")
    fi

    # --- Extra shared environment (non-sensitive config) -----------------
    if [[ -n "${BK_EXTRA_ENV_FILE:-}" && -f "${BK_EXTRA_ENV_FILE}" ]]; then
        args+=(--property="EnvironmentFile=${BK_EXTRA_ENV_FILE}")
    fi

    # --- Agent query rules as env var (informational for hooks) ----------
    local rules_str
    rules_str=$(echo "$query_rules" | jq -r 'join(",")' 2>/dev/null || true)
    if [[ -n "$rules_str" ]]; then
        args+=(--property="Environment=BUILDKITE_AGENT_TAGS=${rules_str}")
    fi

    # --- The actual agent command ----------------------------------------
    # Read the agent token from $CREDENTIALS_DIRECTORY (injected via
    # LoadCredential above). Extracting to a variable avoids backslash
    # continuations inside single quotes, which are literal, not shell escapes.
    local agent_cmd='BUILDKITE_AGENT_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/agent-token") exec buildkite-agent start --disconnect-after-job --no-color --queue "$_BK_QUEUE"'
    args+=(bash -c "$agent_cmd")

    # Execute
    if "${args[@]}"; then
        log_info "Unit ${unit} started successfully"
        notify_job "$job_uuid" "Agent unit started"
    else
        log_error "Failed to start unit ${unit}"
        notify_job "$job_uuid" "ERROR: Failed to start agent unit"
    fi
}

# Stop any agent units that have exceeded the job timeout.
# systemd RuntimeMaxSec should handle this, but this is a belt-and-suspenders
# check for units stuck in activating/deactivating.
reap_stale_units() {
    local unit age_sec threshold_sec

    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue

        # ActiveEnterTimestampMonotonic is microseconds since boot
        local monotonic
        monotonic=$(systemctl show "$unit" --property=ActiveEnterTimestampMonotonic \
            --value 2>/dev/null || echo 0)

        if [[ "$monotonic" -gt 0 ]]; then
            local now_mono
            now_mono=$(awk '{print int($1 * 1000000)}' /proc/uptime)
            age_sec=$(( (now_mono - monotonic) / 1000000 ))

            if [[ "$age_sec" -gt "$BK_JOB_TIMEOUT" ]]; then
                log_warn "Unit ${unit} has been running ${age_sec}s (limit ${BK_JOB_TIMEOUT}s) — stopping"
                systemctl stop "$unit" || true
            fi
        fi
    done < <(systemctl list-units --no-legend --state=active 'bk-agent-*.service' \
                 | awk '{print $1}')
}

# =============================================================================
# Shutdown handling
# =============================================================================

handle_shutdown() {
    log_info "Shutdown signal received — will stop after current poll cycle"
    SHUTDOWN_REQUESTED=1
}

wait_for_agents() {
    log_info "Waiting for running agent units to finish..."
    local waited=0

    while [[ "$(running_agent_count)" -gt 0 ]]; do
        sleep 2
        (( waited += 2 ))
        if [[ "$waited" -ge "$BK_JOB_TIMEOUT" ]]; then
            log_warn "Timed out waiting for agents; forcibly stopping remaining units"
            systemctl stop 'bk-agent-*.service' 2>/dev/null || true
            break
        fi
    done

    log_info "All agent units finished"
}

# =============================================================================
# Main polling loop
# =============================================================================

poll_once() {
    # Respect dispatch_paused
    if dispatch_paused; then
        log_info "Dispatch is paused for queue '${BK_QUEUE}' — skipping poll"
        return
    fi

    local running
    running=$(running_agent_count)
    log_debug "Running agents: ${running}/${BK_MAX_AGENTS}"

    if [[ "$running" -ge "$BK_MAX_AGENTS" ]]; then
        log_debug "At capacity (${running}/${BK_MAX_AGENTS}) — skipping poll"
        return
    fi

    local slots=$(( BK_MAX_AGENTS - running ))
    local jobs_json
    jobs_json=$(get_scheduled_jobs)

    local job_count
    job_count=$(echo "$jobs_json" | jq 'length')
    log_debug "Scheduled jobs available: ${job_count}"

    if [[ "$job_count" -eq 0 ]]; then
        return
    fi

    # Sort by priority descending, then iterate up to available slots
    local processed=0
    while IFS= read -r job; do
        [[ "$processed" -ge "$slots" ]] && break

        local job_uuid priority query_rules
        job_uuid=$(echo    "$job" | jq -r '.id' | tr '[:upper:]' '[:lower:]')
        priority=$(echo    "$job" | jq -r '.priority // 0')
        query_rules=$(echo "$job" | jq -c '.agent_query_rules // []')

        # Validate UUID format before using in unit names and filesystem paths
        if [[ ! "$job_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            log_warn "Skipping job with invalid id format: ${job_uuid}"
            continue
        fi

        log_debug "Considering job ${job_uuid} (priority=${priority})"

        # Attempt to reserve — skip if another instance beat us to it
        if ! reserve_job "$job_uuid"; then
            log_debug "Job ${job_uuid} already claimed — skipping"
            continue
        fi

        spawn_agent "$job_uuid" "$query_rules"
        (( processed++ )) || true

    done < <(echo "$jobs_json" | jq -c 'sort_by(-.priority) | .[]')

    [[ "$processed" -gt 0 ]] && log_info "Spawned ${processed} agent unit(s) this cycle"
}

main() {
    log_info "bk-stack-controller starting (stack=${BK_STACK_KEY} queue=${BK_QUEUE})"

    check_prerequisites

    trap handle_shutdown SIGTERM SIGINT

    register_stack

    log_info "Entering poll loop (interval=${BK_POLL_INTERVAL}s max_agents=${BK_MAX_AGENTS})"

    while [[ "$SHUTDOWN_REQUESTED" -eq 0 ]]; do
        poll_once || log_warn "poll_once encountered an error (will retry)"
        reap_stale_units

        # Interruptible sleep — wakes immediately on signal
        sleep "$BK_POLL_INTERVAL" &
        wait $! 2>/dev/null || true
    done

    wait_for_agents
    log_info "bk-stack-controller stopped cleanly"
}

main "$@"
