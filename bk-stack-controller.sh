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
#   Self-update (run as root):
#     sudo bk-stack-controller.sh --update
#
# ENVIRONMENT (via EnvironmentFile or systemd drop-in)
#   Required (one of):
#     CREDENTIALS_DIRECTORY   Set automatically by systemd when LoadCredential=
#                             agent-token is present in the service unit. The
#                             controller reads the token from
#                             $CREDENTIALS_DIRECTORY/agent-token at startup.
#     BK_AGENT_TOKEN          Fallback: literal token value. Supported for
#                             backward compatibility and manual invocations
#                             outside of systemd.
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
#     CONTROLLER_UPDATE_URL   URL to fetch updates from (optional override)
# =============================================================================

readonly CONTROLLER_VERSION="1.0.0"
readonly CONTROLLER_UPDATE_URL="${CONTROLLER_UPDATE_URL:-https://raw.githubusercontent.com/tomowatt/buildkite-agent-systemd-stack/main/bk-stack-controller.sh}"

set -euo pipefail

# =============================================================================
# Defaults
# =============================================================================

# Required — empty defaults satisfy set -u; check_prerequisites validates non-empty
BK_AGENT_TOKEN="${BK_AGENT_TOKEN:-}"
BK_STACK_KEY="${BK_STACK_KEY:-}"
BK_AGENTAPI_BASE_URL="${BK_AGENTAPI_BASE_URL:-}"

BK_QUEUE="${BK_QUEUE:-default}"
BK_MAX_AGENTS="${BK_MAX_AGENTS:-4}"
BK_POLL_INTERVAL="${BK_POLL_INTERVAL:-5}"
BK_JOB_TIMEOUT="${BK_JOB_TIMEOUT:-3600}"
BK_WORK_DIR="${BK_WORK_DIR:-/var/lib/bk-stack/work}"
BK_LOG_LEVEL="${BK_LOG_LEVEL:-info}"
BK_AGENT_TOKEN_FILE="${BK_AGENT_TOKEN_FILE:-/etc/bk-stack/secrets/agent-token}"
BK_AGENT_CONFIG_FILE="${BK_AGENT_CONFIG_FILE:-/etc/bk-stack/agent.cfg}"

# Internal state
SHUTDOWN_REQUESTED=0
_CURL_AUTH_FILE=""   # set in main() after check_prerequisites; used by api_call()

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

    # Validate that URL-interpolated values contain only safe characters.
    [[ "$BK_STACK_KEY" =~ ^[a-zA-Z0-9_-]+$ ]] || die "BK_STACK_KEY must contain only alphanumeric, dash, or underscore characters"
    [[ "$BK_QUEUE"     =~ ^[a-zA-Z0-9_-]+$ ]] || die "BK_QUEUE must contain only alphanumeric, dash, or underscore characters"

    # Validate that arithmetic-used values are positive non-zero integers.
    # Zero is semantically invalid: 0 agents, 0-second poll (busy-loop), 0-second timeout.
    [[ "$BK_MAX_AGENTS"    =~ ^[1-9][0-9]*$ ]] || die "BK_MAX_AGENTS must be a positive integer (got: ${BK_MAX_AGENTS})"
    [[ "$BK_POLL_INTERVAL" =~ ^[1-9][0-9]*$ ]] || die "BK_POLL_INTERVAL must be a positive integer (got: ${BK_POLL_INTERVAL})"
    [[ "$BK_JOB_TIMEOUT"   =~ ^[1-9][0-9]*$ ]] || die "BK_JOB_TIMEOUT must be a positive integer (got: ${BK_JOB_TIMEOUT})"

    mkdir -p "$BK_WORK_DIR"

    # Ensure git mirrors directory is world-writable without sticky bit.
    # DynamicUser agent units (ephemeral random UIDs) need to create mirror
    # dirs AND delete stale .clonelockf files left by previous unit UIDs.
    # Sticky bit (1777) prevents cross-UID lock file removal, so we use 0777.
    if [[ -n "${BK_GIT_MIRRORS_PATH:-}" && -d "${BK_GIT_MIRRORS_PATH}" ]]; then
        chmod 0777 "${BK_GIT_MIRRORS_PATH}" 2>/dev/null || true
        find "${BK_GIT_MIRRORS_PATH}" -maxdepth 1 -type f -name "*.clonelockf" -delete 2>/dev/null || true
        log_debug "Git mirrors dir ready: ${BK_GIT_MIRRORS_PATH}"
    fi

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

    # Authorization header is read from a curl config file (written at startup)
    # so the token never appears in the curl command line / /proc/PID/cmdline.
    curl --silent --fail-with-body \
        --max-time 30 \
        --config "${_CURL_AUTH_FILE}" \
        -X "$method" \
        -H "Content-Type: application/json" \
        "$@" \
        "$url"
}

# Register this stack with the Buildkite cluster queue.
# The API is idempotent — safe to call on every startup.
register_stack() {
    log_info "Registering stack '${BK_STACK_KEY}' on queue '${BK_QUEUE}'"

    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    local payload
    payload=$(jq -n \
        --arg key      "$BK_STACK_KEY" \
        --arg queue    "$BK_QUEUE" \
        --arg version  "$CONTROLLER_VERSION" \
        --arg hostname "$hostname" \
        '{ key: $key, type: "custom", queue_key: $queue, metadata: { version: $version, hostname: $hostname } }')

    local response
    response=$(api_call POST "/stacks/register" --data "$payload") \
        || die "Failed to register stack. API response: ${response:-<empty>}"

    log_info "Stack registered"
}

# Fetch scheduled jobs for this stack.
# Usage: get_scheduled_jobs <limit>
# Prints the raw API response JSON on success, nothing on failure.
# Returns 0 on success, 1 on API error.
get_scheduled_jobs() {
    local limit="${1:-${BK_MAX_AGENTS}}"
    local path="/stacks/${BK_STACK_KEY}/scheduled-jobs?queue_key=${BK_QUEUE}&limit=${limit}"
    local raw
    if ! raw=$(api_call GET "$path" 2>/dev/null); then
        log_warn "Failed to fetch scheduled jobs — API response: ${raw:-<empty>}"
        return 1
    fi
    echo "$raw"
}

# Batch-reserve a set of jobs so no other stack instance claims them.
# Usage: reserve_jobs_batch <uuids_json>
#   uuids_json — JSON array of UUID strings to reserve
# Prints a JSON array of successfully reserved UUIDs.
# Returns 0 on success, 0 with empty array on API error (non-fatal).
reserve_jobs_batch() {
    local uuids_json="$1"
    local expiry=$(( BK_JOB_TIMEOUT < 3600 ? BK_JOB_TIMEOUT : 3600 ))

    local payload
    payload=$(jq -n \
        --argjson uuids   "$uuids_json" \
        --argjson expiry  "$expiry" \
        '{ job_uuids: $uuids, reservation_expiry_seconds: $expiry }')

    local response
    if ! response=$(api_call PUT \
            "/stacks/${BK_STACK_KEY}/scheduled-jobs/batch-reserve" \
            --data "$payload" 2>/dev/null); then
        log_warn "Batch reserve failed — API response: ${response:-<empty>}"
        echo "[]"
        return 0
    fi

    echo "$response" | jq -c '.reserved // []'
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

# Finish a job via the Stacks API without spawning an agent.
# Call when the stack cannot start an agent due to an infrastructure problem
# (e.g. disk full, systemd-run failure). The job will appear as failed on the
# Buildkite build page with a special marker and the provided detail message.
# The API accepts this call at most once per job.
# Usage: finish_job <job_uuid> <exit_status> <detail>
# Non-fatal — errors are logged but do not abort the controller.
finish_job() {
    local job_uuid="$1" exit_status="$2" detail="$3"

    # The API enforces a 4096-byte maximum on the detail field.
    if [[ ${#detail} -gt 4096 ]]; then
        detail="${detail:0:4093}..."
    fi

    local payload
    payload=$(jq -n \
        --argjson status "$exit_status" \
        --arg    detail "$detail" \
        '{ exit_status: $status, detail: $detail }')

    if api_call POST "/stacks/${BK_STACK_KEY}/jobs/${job_uuid}/finish" \
            --data "$payload" > /dev/null 2>&1; then
        log_info "Job ${job_uuid} finished via API (exit_status=${exit_status})"
    else
        log_warn "Failed to call finish-job API for ${job_uuid}"
    fi
}


# =============================================================================
# Agent unit management
# =============================================================================

# Return the systemd unit name for a given job UUID.
unit_name() {
    echo "bk-agent-${1}.service"
}

# Count currently running agent units.
# Uses awk instead of wc -l to avoid counting blank or summary lines that
# some systemd versions emit even with --no-legend.
running_agent_count() {
    systemctl list-units --no-legend --state=active,activating 'bk-agent-*.service' \
        | awk '/bk-agent-/{n++} END{print n+0}'
}

# Build the systemd-run invocation for a single job, then execute it.
# Usage: spawn_agent <job_uuid> <agent_query_rules_json>
spawn_agent() {
    local job_uuid="$1"
    local query_rules="$2"
    local unit
    unit=$(unit_name "$job_uuid")
    local work_dir="${BK_WORK_DIR}/${job_uuid}"

    if ! mkdir -p "$work_dir"; then
        log_error "Failed to create work directory ${work_dir} for job ${job_uuid}"
        finish_job "$job_uuid" -1 \
            "Stack failed to create agent work directory: ${work_dir}"
        return 1
    fi
    # World-writable + sticky bit: DynamicUser (random UID) needs write access,
    # but the sticky bit prevents one job's UID from deleting another's files.
    chmod 1777 "$work_dir" 2>/dev/null || true

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

        # DynamicUser has no home directory; HOME=/tmp points to the per-unit
        # private /tmp namespace (from PrivateTmp=yes), giving the agent a
        # writable location for ~/.ssh/known_hosts and other home-dir state.
        --property="Environment=HOME=/tmp"

        # --- Resource limits ---------------------------------------------
        --property="MemoryMax=4G"
        --property="CPUQuota=200%"
        --property="TasksMax=512"

        # Watchdog: abort the unit if it runs over the job timeout
        --property="RuntimeMaxSec=${BK_JOB_TIMEOUT}"

        # --- Working directory -------------------------------------------
        # DynamicUser=yes implies ProtectSystem=strict (read-only filesystem).
        # ReadWritePaths overrides that for the per-job work directory.
        --property="WorkingDirectory=${work_dir}"
        --property="ReadWritePaths=${work_dir}"
        --property="Environment=BUILDKITE_BUILD_PATH=${work_dir}"

        # --- Agent token & job targeting ---------------------------------
        # Token injected via LoadCredential (file reference, never on the
        # command line) so it is NOT visible via `systemctl show` or /proc.
        --property="LoadCredential=agent-token:${BK_AGENT_TOKEN_FILE}"
        --property="Environment=BUILDKITE_AGENT_ACQUIRE_JOB=${job_uuid}"

        # Queue name is non-sensitive; passed as env so the shell wrapper below
        # can forward it to buildkite-agent without hardcoding it in the args.
        --property="Environment=_BK_QUEUE=${BK_QUEUE}"

        # Agent config file path; world-readable so DynamicUser can access it.
        --property="Environment=_BK_AGENT_CFG=${BK_AGENT_CONFIG_FILE}"
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
    # Uses a heredoc so the script can span multiple lines without quoting
    # gymnastics. Variables like $CREDENTIALS_DIRECTORY are NOT expanded here
    # (the heredoc delimiter is quoted); bash -c expands them at runtime.
    local agent_cmd
    agent_cmd=$(cat <<'AGENT_CMD'
    # DynamicUser=yes allocates an ephemeral UID not present in /etc/passwd.
    # SSH and git call getpwuid() which returns NULL for unknown UIDs, causing
    # "No user exists for uid XXXXX" errors and connection failures.
    # libnss-wrapper intercepts NSS calls and returns a synthetic passwd entry.
    _uid=$(id -u); _gid=$(id -g)
    printf 'bk-agent:x:%d:%d:Buildkite Agent:/tmp:/bin/sh\n' "$_uid" "$_gid" > /tmp/nss_passwd
    printf 'bk-agent:x:%d:\n' "$_gid" > /tmp/nss_group
    _nss=$(ldconfig -p 2>/dev/null | awk '/libnss_wrapper\.so/{print $NF; exit}')
    if [[ "$_nss" =~ ^(/usr/lib|/usr/lib64|/lib|/lib64)/ ]]; then
        export LD_PRELOAD="$_nss"
        export NSS_WRAPPER_PASSWD=/tmp/nss_passwd
        export NSS_WRAPPER_GROUP=/tmp/nss_group
    fi
    # Load the SSH key (injected via LoadCredential) into a per-job ssh-agent.
    if [[ -f "$CREDENTIALS_DIRECTORY/ssh-key" ]]; then
        _agent_out=$(ssh-agent -s)
        SSH_AUTH_SOCK=$(printf '%s' "$_agent_out" | grep -oP '(?<=SSH_AUTH_SOCK=)[^;]+')
        SSH_AGENT_PID=$(printf '%s' "$_agent_out" | grep -oP '(?<=SSH_AGENT_PID=)[^;]+')
        export SSH_AUTH_SOCK SSH_AGENT_PID
        trap 'ssh-agent -k 2>/dev/null || true' EXIT
        ssh-add "$CREDENTIALS_DIRECTORY/ssh-key" 2>/dev/null || true
    fi
    # Do NOT use exec here: exec replaces the shell process so the EXIT trap
    # set above (ssh-agent -k) would never fire, leaking the ssh-agent daemon.
    # The slight overhead of keeping the bash wrapper alive is negligible.
    BUILDKITE_AGENT_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/agent-token") \
        buildkite-agent start --config "$_BK_AGENT_CFG" \
            --disconnect-after-job --no-color --queue "$_BK_QUEUE"
AGENT_CMD
)
    args+=(bash -c "$agent_cmd")

    # Execute
    if "${args[@]}"; then
        log_info "Unit ${unit} started successfully"
        notify_job "$job_uuid" "Agent unit started"
    else
        local rc=$?
        log_error "Failed to start unit ${unit} (systemd-run exit code: ${rc})"
        notify_job "$job_uuid" "ERROR: Failed to start agent unit"
        finish_job "$job_uuid" -1 \
            "Stack failed to start agent unit ${unit} (systemd-run exit code: ${rc})"
    fi
}

# Stop any agent units that have exceeded the job timeout.
# systemd RuntimeMaxSec should handle this, but this is a belt-and-suspenders
# check for units stuck in activating/deactivating.
reap_stale_units() {
    local unit age_sec

    while IFS= read -r unit; do
        [[ -z "$unit" ]] && continue

        # ActiveEnterTimestampMonotonic is microseconds since boot
        local monotonic
        monotonic=$(systemctl show "$unit" --property=ActiveEnterTimestampMonotonic \
            --value 2>/dev/null || echo 0)

        if [[ "$monotonic" =~ ^[0-9]+$ ]] && [[ "$monotonic" -gt 0 ]]; then
            local now_mono
            now_mono=$(awk '{printf "%d\n", $1 * 1000000}' /proc/uptime)
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

poll_once() {
    local running
    running=$(running_agent_count)
    log_debug "Running agents: ${running}/${BK_MAX_AGENTS}"

    if [[ "$running" -ge "$BK_MAX_AGENTS" ]]; then
        log_debug "At capacity (${running}/${BK_MAX_AGENTS}) — skipping poll"
        return 0
    fi

    local slots=$(( BK_MAX_AGENTS - running ))

    # Single API call: scheduled jobs + dispatch state in one response
    local response
    # Fetch up to BK_MAX_AGENTS candidates (more than slots) so reservation
    # failures from competing instances don't leave slots unfilled.
    response=$(get_scheduled_jobs "${BK_MAX_AGENTS}") || return 0

    # Respect dispatch_paused from the response
    if [[ "$(echo "$response" | jq -r '.cluster_queue.dispatch_paused // false')" == "true" ]]; then
        log_info "Dispatch is paused for queue '${BK_QUEUE}' — skipping poll"
        return 0
    fi

    local jobs_json
    jobs_json=$(echo "$response" | jq -c '.jobs // []')

    local job_count
    job_count=$(echo "$jobs_json" | jq 'length')

    if [[ "$job_count" -eq 0 ]]; then
        log_debug "No scheduled jobs"
        return 0
    fi

    log_info "Scheduled jobs: ${job_count} available, ${slots} slot(s) open"

    # --- Pass 1: validate UUIDs and build candidate list (priority order) ---
    local candidate_uuids='[]'
    local job_map='{}'

    while IFS= read -r job; do
        [[ "$(echo "$candidate_uuids" | jq 'length')" -ge "$slots" ]] && break

        local job_uuid
        job_uuid=$(echo "$job" | jq -r '.id' | tr '[:upper:]' '[:lower:]')

        if [[ ! "$job_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            log_warn "Skipping job with invalid id format: ${job_uuid}"
            continue
        fi

        candidate_uuids=$(echo "$candidate_uuids" | jq -c --arg u "$job_uuid" '. + [$u]')
        job_map=$(echo "$job_map" | jq -c --arg u "$job_uuid" --argjson job "$job" '. + {($u): $job}')

    done < <(echo "$jobs_json" | jq -c 'sort_by(-(.priority // 0)) | .[]')

    local candidate_count
    candidate_count=$(echo "$candidate_uuids" | jq 'length')
    log_debug "Attempting to reserve ${candidate_count} job(s)"

    # --- Single batch reserve call ---
    local reserved_json
    reserved_json=$(reserve_jobs_batch "$candidate_uuids")

    local reserved_count
    reserved_count=$(echo "$reserved_json" | jq 'length')
    log_info "Reserved ${reserved_count}/${candidate_count} job(s)"

    # --- Pass 2: spawn agents for reserved jobs (priority order preserved) ---
    local processed=0
    while IFS= read -r job_uuid; do
        local query_rules
        query_rules=$(echo "$job_map" | jq -c --arg u "$job_uuid" '.[$u].agent_query_rules // []')

        spawn_agent "$job_uuid" "$query_rules"
        (( processed++ )) || true

    done < <(echo "$candidate_uuids" | \
        jq -r --argjson reserved "$reserved_json" \
        '.[] | select(. as $u | $reserved | index($u) != null)')

    if [[ "$processed" -gt 0 ]]; then
        log_info "Spawned ${processed} agent unit(s) this cycle"
    fi
}

# =============================================================================
# Self-update
# =============================================================================

# Download, validate, and replace the running script.
# Must be run as root; the service user cannot write to /usr/local/bin.
do_self_update() {
    [[ "$EUID" -eq 0 ]] || die "--update must be run as root (try: sudo $0 --update)"

    echo "Fetching latest controller from ${CONTROLLER_UPDATE_URL} ..."

    local tmp
    tmp=$(mktemp /tmp/bk-stack-controller-XXXXXX.sh)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp'" EXIT

    curl --fail --location --max-time 30 \
        --output "$tmp" \
        "$CONTROLLER_UPDATE_URL" \
        || die "Download failed"

    bash -n "$tmp" || die "Downloaded script failed syntax check — aborting update"

    local new_version
    new_version=$(grep -m1 '^readonly CONTROLLER_VERSION=' "$tmp" | cut -d'"' -f2)

    if [[ -z "$new_version" ]]; then
        die "Could not determine version of downloaded script — aborting update"
    fi

    if [[ "$new_version" == "$CONTROLLER_VERSION" ]]; then
        echo "Already at version ${CONTROLLER_VERSION} — nothing to do."
        exit 0
    fi

    local script_path
    script_path=$(readlink -f "$0")

    install -m 755 -o root -g root "$tmp" "$script_path"

    echo "Updated: v${CONTROLLER_VERSION} → v${new_version}"
    echo "Restart the service to apply: sudo systemctl restart bk-stack-controller"
}

# On startup: fetch the remote version string and warn if a newer version exists.
# Non-fatal — a network error just skips the check.
check_for_update() {
    local remote_version
    remote_version=$(curl --silent --fail --max-time 10 "$CONTROLLER_UPDATE_URL" 2>/dev/null \
        | grep -m1 '^readonly CONTROLLER_VERSION=' | cut -d'"' -f2) || return 0

    [[ -z "$remote_version" ]] && return 0
    [[ "$remote_version" == "$CONTROLLER_VERSION" ]] && return 0

    log_warn "Update available: v${remote_version} (running v${CONTROLLER_VERSION})"
    log_warn "To update: sudo bk-stack-controller.sh --update && sudo systemctl restart bk-stack-controller"
}

# =============================================================================
# Main polling loop
# =============================================================================

main() {
    if [[ "${1:-}" == "--update" ]]; then
        do_self_update
        exit 0
    fi

    log_info "bk-stack-controller starting (stack=${BK_STACK_KEY} queue=${BK_QUEUE}) v${CONTROLLER_VERSION}"

    # Load the agent token from the systemd credential file (injected via
    # LoadCredential=agent-token in the service unit). Falls back to the
    # BK_AGENT_TOKEN env var for backward compatibility and manual invocations.
    if [[ -z "${BK_AGENT_TOKEN:-}" && \
          -n "${CREDENTIALS_DIRECTORY:-}" && \
          -f "${CREDENTIALS_DIRECTORY}/agent-token" ]]; then
        BK_AGENT_TOKEN=$(< "${CREDENTIALS_DIRECTORY}/agent-token")
    fi

    check_prerequisites

    # Write the Authorization header to a private temp file so the agent token
    # never appears in the curl command line or /proc/<pid>/cmdline.
    _CURL_AUTH_FILE=$(mktemp /tmp/bk-stack-curl-XXXXXX)
    chmod 600 "$_CURL_AUTH_FILE"
    printf 'header = "Authorization: Token %s"\n' "$BK_AGENT_TOKEN" > "$_CURL_AUTH_FILE"
    # shellcheck disable=SC2064
    trap "rm -f '${_CURL_AUTH_FILE}'" EXIT

    check_for_update

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
