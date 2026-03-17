#!/usr/bin/env bash
# =============================================================================
# install.sh — Buildkite Stack Controller Installer
#
# Interactive setup script. Installs the controller daemon, systemd service,
# and walks the user through all configuration variables.
#
# USAGE
#   # Install directly from GitHub:
#   bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/YOUR_REPO/main/install.sh)
#
#   # Or clone and run locally:
#   git clone https://github.com/YOUR_ORG/YOUR_REPO
#   cd YOUR_REPO && bash install.sh
#
# OPTIONS
#   --unattended      Skip prompts; requires all BK_* env vars to be pre-set
#   --uninstall       Remove the controller, service, and config files
#   --dry-run         Show what would be done without making changes
# =============================================================================

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly SCRIPT_VERSION="1.0.0"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/etc/bk-stack"
readonly SECRETS_DIR="/etc/bk-stack/secrets"
readonly WORK_DIR="/var/lib/bk-stack/work"
readonly GIT_MIRRORS_DIR="/var/cache/bk-git-mirrors"
readonly CACHE_DIR="/var/cache/bk-cache"
readonly SERVICE_NAME="bk-stack-controller"
readonly SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
readonly CONTROLLER_SCRIPT="${INSTALL_DIR}/bk-stack-controller.sh"
readonly ENV_FILE="${CONFIG_DIR}/controller.env"
readonly AGENT_CONFIG_FILE="${CONFIG_DIR}/agent.cfg"
readonly SERVICE_USER="bk-stack"
readonly POLKIT_RULES_FILE="/etc/polkit-1/rules.d/50-bk-stack.rules"

# GitHub raw URL for the controller script (update to match your repo)
readonly CONTROLLER_SCRIPT_URL="${CONTROLLER_SCRIPT_URL:-https://raw.githubusercontent.com/tomowatt/buildkite-agent-systemd-stack/main/bk-stack-controller.sh}"

# Flags
UNATTENDED=0
UNINSTALL=0
DRY_RUN=0

# Collected config values (populated during prompts)
declare -A CFG

# =============================================================================
# Colours & output
# =============================================================================

# Detect colour support
if [[ -t 1 ]] && command -v tput &>/dev/null && tput colors &>/dev/null; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    DIM=$(tput dim)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" BLUE="" CYAN="" BOLD="" DIM="" RESET=""
fi

print_header() {
    echo
    echo "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo "${BOLD}${BLUE}║       Buildkite Stack Controller — Installer v${SCRIPT_VERSION}      ║${RESET}"
    echo "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo
}

print_section() {
    echo
    echo "${BOLD}${CYAN}▶ $*${RESET}"
    echo "${DIM}$(printf '─%.0s' {1..60})${RESET}"
}

print_step() {
    echo "  ${GREEN}•${RESET} $*"
}

print_info() {
    echo "  ${BLUE}ℹ${RESET}  $*"
}

print_warn() {
    echo "  ${YELLOW}⚠${RESET}  $*" >&2
}

print_error() {
    echo "  ${RED}✖${RESET}  $*" >&2
}

print_success() {
    echo "  ${GREEN}✔${RESET}  $*"
}

die() {
    print_error "$*"
    exit 1
}

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  ${DIM}[dry-run]${RESET} $*"
    else
        "$@"
    fi
}

run_quiet() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  ${DIM}[dry-run]${RESET} $*"
    else
        "$@" > /dev/null 2>&1
    fi
}

# =============================================================================
# Argument parsing
# =============================================================================

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --unattended) UNATTENDED=1 ;;
            --uninstall)  UNINSTALL=1  ;;
            --dry-run)    DRY_RUN=1    ;;
            -h|--help)
                echo "Usage: $0 [--unattended] [--uninstall] [--dry-run]"
                exit 0
                ;;
            *)
                die "Unknown option: $1  (try --help)"
                ;;
        esac
        shift
    done
}

# =============================================================================
# Preflight checks
# =============================================================================

check_root() {
    [[ "$EUID" -eq 0 ]] || die "This installer must be run as root (try: sudo bash $0)"
}

check_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS. This installer supports systemd-based Linux only."
    fi

    if ! command -v systemctl &>/dev/null; then
        die "systemd is required but not found."
    fi

    # Warn on older systemd versions that lack DynamicUser
    local systemd_ver
    systemd_ver=$(systemctl --version | head -1 | awk '{print $2}')
    if [[ "$systemd_ver" -lt 247 ]]; then
        print_warn "systemd ${systemd_ver} detected. Version 247+ is required (SetCredential support for agent token isolation)."
    fi
}

check_dependencies() {
    print_section "Checking dependencies"
    local missing=()
    for cmd in curl jq systemd-run systemctl; do
        if command -v "$cmd" &>/dev/null; then
            print_success "$cmd found"
        else
            missing+=("$cmd")
            print_error "$cmd not found"
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo
        print_warn "Missing dependencies: ${missing[*]}"
        print_info "Install them with:"
        # Detect package manager
        if command -v apt-get &>/dev/null; then
            print_info "  apt-get install -y ${missing[*]}"
        elif command -v dnf &>/dev/null; then
            print_info "  dnf install -y ${missing[*]}"
        elif command -v yum &>/dev/null; then
            print_info "  yum install -y ${missing[*]}"
        fi
        echo
        read -r -p "  Attempt automatic installation? [y/N] " auto_install
        if [[ "${auto_install,,}" == "y" ]]; then
            install_dependencies "${missing[@]}"
        else
            die "Please install missing dependencies and re-run."
        fi
    fi
}

install_dependencies() {
    local pkgs=("$@")
    if command -v apt-get &>/dev/null; then
        run apt-get install -y "${pkgs[@]}"
    elif command -v dnf &>/dev/null; then
        run dnf install -y "${pkgs[@]}"
    elif command -v yum &>/dev/null; then
        run yum install -y "${pkgs[@]}"
    else
        die "Could not auto-install. Please install manually: ${pkgs[*]}"
    fi
}

# =============================================================================
# Interactive prompt helpers
# =============================================================================

# prompt_path <var_name> <display_name> <description> <default>
# Like prompt, but rejects values that are not absolute paths.
prompt_path() {
    local var="$1" display="$2" description="$3" default="$4"

    if [[ "$UNATTENDED" -eq 1 ]]; then
        local val="${!var:-$default}"
        [[ "$val" == /* ]] || die "${var} must be an absolute path, got: ${val}"
        CFG[$var]="$val"
        return
    fi

    echo
    echo "  ${BOLD}${display}${RESET}"
    echo "  ${DIM}${description}${RESET}"
    [[ -n "$default" ]] && echo "  ${DIM}Default: ${default}${RESET}"

    local value
    while true; do
        read -r -p "  ▸ " value
        [[ -z "$value" && -n "$default" ]] && value="$default"
        if [[ -z "$value" ]]; then
            print_warn "This field is required."
            continue
        fi
        if [[ "$value" != /* ]]; then
            print_warn "Path must be absolute (start with /). Got: ${value}"
            continue
        fi
        break
    done

    CFG[$var]="$value"
}

# prompt <var_name> <display_name> <description> <default> [secret]
# Reads a value interactively (or from env in unattended mode) and stores
# it in the CFG associative array.
prompt() {
    local var="$1" display="$2" description="$3" default="$4" secret="${5:-}"

    # In unattended mode pull from environment, fall back to default
    if [[ "$UNATTENDED" -eq 1 ]]; then
        CFG[$var]="${!var:-$default}"
        return
    fi

    echo
    echo "  ${BOLD}${display}${RESET}"
    echo "  ${DIM}${description}${RESET}"
    if [[ -n "$default" ]]; then
        echo "  ${DIM}Default: ${default}${RESET}"
    fi

    local value
    while true; do
        if [[ -n "$secret" ]]; then
            read -r -s -p "  ▸ " value
            echo  # newline after hidden input
        else
            read -r -p "  ▸ " value
        fi

        # Use default if empty
        if [[ -z "$value" && -n "$default" ]]; then
            value="$default"
        fi

        # Re-prompt if required and still empty
        if [[ -z "$value" && -z "$default" ]]; then
            print_warn "This field is required."
            continue
        fi

        break
    done

    CFG[$var]="$value"
}

# yes_no <var_name> <question> <default: y|n>
yes_no() {
    local var="$1" question="$2" default="${3:-n}"
    local hint
    if [[ "$default" == "y" ]]; then hint="[Y/n]"; else hint="[y/N]"; fi

    if [[ "$UNATTENDED" -eq 1 ]]; then
        CFG[$var]="${!var:-$default}"
        return
    fi

    echo
    local answer
    read -r -p "  ${BOLD}${question}${RESET} ${DIM}${hint}${RESET} " answer
    answer="${answer:-$default}"
    CFG[$var]="${answer,,}"
}

# =============================================================================
# Configuration sections
# =============================================================================

collect_required_config() {
    print_section "Required configuration"

    prompt "BK_AGENT_TOKEN" \
        "Buildkite Agent Token" \
        "Your Buildkite cluster agent token. Found in Buildkite → Clusters → Agent Tokens." \
        "" \
        "secret"

    prompt "BK_STACK_KEY" \
        "Stack Key" \
        "A unique identifier for this stack instance. Use something stable like the hostname or a descriptive name. Must be unique across all stacks in your cluster." \
        "$(hostname -s)-stack"

    prompt "BK_AGENTAPI_BASE_URL" \
        "Agent API Base URL" \
        "Base URL for the Buildkite Agent API." \
        "https://agent.buildkite.com/v3"
}

collect_queue_config() {
    print_section "Queue & concurrency"

    prompt "BK_QUEUE" \
        "Queue name" \
        "The Buildkite cluster queue this stack will serve." \
        "default"

    prompt "BK_MAX_AGENTS" \
        "Maximum concurrent agents" \
        "The maximum number of agent units to run in parallel on this host. A good starting point is the number of CPU cores." \
        "$(nproc 2>/dev/null || echo 4)"

    prompt "BK_POLL_INTERVAL" \
        "Poll interval (seconds)" \
        "How often to check the Stacks API for new scheduled jobs." \
        "5"

    prompt "BK_JOB_TIMEOUT" \
        "Job timeout (seconds)" \
        "Maximum wall-clock time a single job unit may run before being killed." \
        "3600"
}

collect_paths_config() {
    print_section "Paths & shared directories"

    prompt_path "BK_WORK_DIR" \
        "Agent workspace directory" \
        "Root directory for per-job build workspaces. Each job gets its own subdirectory here." \
        "$WORK_DIR"

    yes_no "use_git_mirrors" \
        "Enable shared git mirrors? (Recommended — dramatically speeds up clones)" \
        "y"

    if [[ "${CFG[use_git_mirrors]}" == "y" ]]; then
        prompt_path "BK_GIT_MIRRORS_PATH" \
            "Git mirrors path" \
            "Directory for shared bare-repo git mirrors. Agents clone with --reference pointing here." \
            "$GIT_MIRRORS_DIR"
    else
        CFG[BK_GIT_MIRRORS_PATH]=""
    fi

    yes_no "use_cache" \
        "Enable shared dependency cache?" \
        "y"

    if [[ "${CFG[use_cache]}" == "y" ]]; then
        prompt_path "BK_CACHE_PATH" \
            "Dependency cache path" \
            "Root directory for shared dependency caches (npm, pip, Go modules, etc.). Bind-mounted read-only into each agent unit." \
            "$CACHE_DIR"
    else
        CFG[BK_CACHE_PATH]=""
    fi
}

collect_ssh_config() {
    print_section "SSH credential configuration"

    echo
    print_info "The controller can provide SSH credentials to agents in two ways:"
    echo
    echo "    ${BOLD}A)${RESET} LoadCredential ${DIM}(recommended)${RESET}"
    echo "       Each agent unit receives the SSH key via a systemd credential."
    echo "       The key is only visible inside that unit's process tree."
    echo
    echo "    ${BOLD}B)${RESET} Shared ssh-agent socket"
    echo "       All agents connect to a single long-running ssh-agent daemon."
    echo "       Simpler, but all concurrent jobs share the same agent socket."
    echo
    echo "    ${BOLD}C)${RESET} None ${DIM}(configure SSH separately via hooks)${RESET}"
    echo

    local ssh_choice
    if [[ "$UNATTENDED" -eq 1 ]]; then
        ssh_choice="${SSH_METHOD:-A}"
    else
        read -r -p "  ▸ Choose A, B, or C [A]: " ssh_choice
        ssh_choice="${ssh_choice:-A}"
    fi

    case "${ssh_choice^^}" in
        A)
            prompt_path "BK_CREDENTIAL_SSH_KEY" \
                "SSH private key path" \
                "Absolute path to the SSH private key file on this host. It will be injected into each agent unit via systemd LoadCredential." \
                "${SECRETS_DIR}/id_ed25519"
            CFG[BK_SSH_AGENT_SOCK]=""

            # Offer to generate a key if the file doesn't exist yet
            local key_path="${CFG[BK_CREDENTIAL_SSH_KEY]}"
            if [[ ! -f "$key_path" ]]; then
                yes_no "gen_ssh_key" \
                    "Key not found at ${key_path}. Generate a new ed25519 key now?" \
                    "y"
                if [[ "${CFG[gen_ssh_key]}" == "y" ]]; then
                    CFG[do_gen_ssh_key]="y"
                fi
            fi
            ;;
        B)
            prompt_path "BK_SSH_AGENT_SOCK" \
                "ssh-agent socket path" \
                "Path to the shared ssh-agent Unix socket." \
                "/run/bk-ssh-agent.sock"
            CFG[BK_CREDENTIAL_SSH_KEY]=""
            ;;
        C)
            CFG[BK_CREDENTIAL_SSH_KEY]=""
            CFG[BK_SSH_AGENT_SOCK]=""
            print_info "No SSH method selected. Configure SSH manually via agent hooks."
            ;;
        *)
            print_warn "Invalid choice '${ssh_choice}', defaulting to None."
            CFG[BK_CREDENTIAL_SSH_KEY]=""
            CFG[BK_SSH_AGENT_SOCK]=""
            ;;
    esac
}

collect_logging_config() {
    print_section "Logging"

    echo
    echo "  Log level options:"
    echo "    ${DIM}debug${RESET}  — verbose, includes every API call"
    echo "    ${DIM}info${RESET}   — normal operational output (recommended)"
    echo "    ${DIM}warn${RESET}   — warnings and errors only"
    echo "    ${DIM}error${RESET}  — errors only"

    prompt "BK_LOG_LEVEL" \
        "Log level" \
        "" \
        "info"
}

# =============================================================================
# Review & confirm
# =============================================================================

review_config() {
    print_section "Configuration summary"
    echo
    printf "  %-35s %s\n" "Setting" "Value"
    printf "  %-35s %s\n" "$(printf '─%.0s' {1..35})" "$(printf '─%.0s' {1..30})"

    local key
    for key in \
        BK_STACK_KEY BK_AGENTAPI_BASE_URL BK_QUEUE \
        BK_MAX_AGENTS BK_POLL_INTERVAL BK_JOB_TIMEOUT \
        BK_WORK_DIR BK_GIT_MIRRORS_PATH BK_CACHE_PATH \
        BK_CREDENTIAL_SSH_KEY BK_SSH_AGENT_SOCK BK_LOG_LEVEL
    do
        local val="${CFG[$key]:-}"
        [[ -z "$val" ]] && val="${DIM}(not set)${RESET}"
        printf "  %-35s %s\n" "$key" "$val"
    done

    # Mask the token
    echo
    printf "  %-35s %s\n" "BK_AGENT_TOKEN" "${DIM}(set — hidden)${RESET}"

    echo

    if [[ "$UNATTENDED" -eq 0 ]]; then
        read -r -p "  Proceed with this configuration? [Y/n] " confirm
        confirm="${confirm:-y}"
        [[ "${confirm,,}" == "y" ]] || die "Installation cancelled."
    fi
}

# =============================================================================
# Installation steps
# =============================================================================

install_polkit_rule() {
    print_section "Installing polkit rule"

    local rules_dir
    rules_dir=$(dirname "$POLKIT_RULES_FILE")

    if [[ ! -d "$rules_dir" ]]; then
        print_warn "polkit rules directory ${rules_dir} not found — skipping"
        print_warn "You may need to grant '${SERVICE_USER}' permission to manage units manually"
        return 0
    fi

    local tmp_rules
    tmp_rules=$(mktemp)

    cat > "$tmp_rules" << 'RULESEOF'
// Allow the bk-stack service user to start transient systemd units via
// systemd-run without interactive authentication.
polkit.addRule(function(action, subject) {
    if (action.id === "org.freedesktop.systemd1.manage-units" &&
        subject.user === "bk-stack") {
        return polkit.Result.YES;
    }
});
RULESEOF

    run install -m 644 -o root -g root "$tmp_rules" "$POLKIT_RULES_FILE"
    rm -f "$tmp_rules"

    print_success "polkit rule written to ${POLKIT_RULES_FILE}"
}

create_user() {
    print_section "Creating service user"
    if id "$SERVICE_USER" &>/dev/null; then
        print_info "User '${SERVICE_USER}' already exists — skipping"
    else
        run useradd \
            --system \
            --no-create-home \
            --shell /usr/sbin/nologin \
            --comment "Buildkite Stack Controller" \
            "$SERVICE_USER"
        print_success "Created system user '${SERVICE_USER}'"
    fi
}

create_directories() {
    print_section "Creating directories"

    local dirs=(
        "$CONFIG_DIR"
        "$SECRETS_DIR"
        "${CFG[BK_WORK_DIR]}"
    )
    [[ -n "${CFG[BK_GIT_MIRRORS_PATH]:-}" ]] && dirs+=("${CFG[BK_GIT_MIRRORS_PATH]}")
    [[ -n "${CFG[BK_CACHE_PATH]:-}" ]]        && dirs+=("${CFG[BK_CACHE_PATH]}")

    for dir in "${dirs[@]}"; do
        run mkdir -p "$dir"
        print_success "Created $dir"
    done

    # Lock down the secrets directory
    run chmod 700 "$SECRETS_DIR"
    run chown root:root "$SECRETS_DIR"

    # Workspace dir owned by bk-stack so the controller can create subdirs
    run chown "${SERVICE_USER}:${SERVICE_USER}" "${CFG[BK_WORK_DIR]}"

    # Git mirrors must be world-writable (sticky bit) so DynamicUser agent
    # units (ephemeral random UIDs) can create and update mirror directories.
    if [[ -n "${CFG[BK_GIT_MIRRORS_PATH]:-}" ]]; then
        run chown "${SERVICE_USER}:${SERVICE_USER}" "${CFG[BK_GIT_MIRRORS_PATH]}"
        run chmod 1777 "${CFG[BK_GIT_MIRRORS_PATH]}"
    fi
    [[ -n "${CFG[BK_CACHE_PATH]:-}" ]] && run chown "${SERVICE_USER}:${SERVICE_USER}" "${CFG[BK_CACHE_PATH]}"
}

write_agent_token_file() {
    print_section "Writing agent token credential file"

    local token_file="${SECRETS_DIR}/agent-token"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        # Write token value with no trailing newline so LoadCredential reads it cleanly
        printf '%s' "${CFG[BK_AGENT_TOKEN]}" > "$token_file"
        chmod 400 "$token_file"
        chown root:root "$token_file"
    else
        echo "  ${DIM}[dry-run]${RESET} printf token > ${token_file} (chmod 400)"
    fi

    print_success "Agent token written to ${token_file} (mode 400, root:root)"
}

generate_ssh_key() {
    [[ "${CFG[do_gen_ssh_key]:-}" != "y" ]] && return

    print_section "Generating SSH key"

    local key_path="${CFG[BK_CREDENTIAL_SSH_KEY]}"
    local key_dir
    key_dir=$(dirname "$key_path")

    run mkdir -p "$key_dir"
    run chmod 700 "$key_dir"

    if [[ "$DRY_RUN" -eq 0 ]]; then
        ssh-keygen -t ed25519 -N "" -C "bk-stack@$(hostname -f)" -f "$key_path"
        chmod 600 "$key_path"
        chmod 644 "${key_path}.pub"
    else
        echo "  ${DIM}[dry-run]${RESET} ssh-keygen -t ed25519 -f ${key_path}"
    fi

    print_success "Generated SSH key: ${key_path}"
    echo
    print_warn "Add this public key to your git hosting provider (GitHub, GitLab, etc.):"
    echo
    if [[ -f "${key_path}.pub" ]]; then
        echo "  ${BOLD}$(cat "${key_path}.pub")${RESET}"
    else
        echo "  ${DIM}(dry-run — key not yet generated)${RESET}"
    fi
    echo
    read -r -p "  Press Enter to continue once you've added the deploy key... "
}

install_controller_script() {
    print_section "Installing controller script"

    # If we're running from within a cloned repo, use the local copy.
    # Otherwise download from GitHub.
    local source_script
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    if [[ -f "${script_dir}/bk-stack-controller.sh" ]]; then
        source_script="${script_dir}/bk-stack-controller.sh"
        print_info "Using local copy: ${source_script}"
    else
        print_info "Downloading from: ${CONTROLLER_SCRIPT_URL}"
        source_script="$(mktemp /tmp/bk-stack-controller-XXXXXX.sh)"
        # shellcheck disable=SC2064
        trap "rm -f ${source_script}" EXIT

        if [[ "$DRY_RUN" -eq 0 ]]; then
            curl --silent --fail --location \
                --output "$source_script" \
                "$CONTROLLER_SCRIPT_URL" \
                || die "Failed to download controller script from ${CONTROLLER_SCRIPT_URL}"
        fi
    fi

    run install -m 755 -o root -g root "$source_script" "$CONTROLLER_SCRIPT"
    print_success "Installed controller script to ${CONTROLLER_SCRIPT}"
}

write_env_file() {
    print_section "Writing configuration file"

    local tmp_env
    tmp_env=$(mktemp)

    # Static structure uses a quoted heredoc (no shell expansion).
    # Variable values are written via printf '%s' so special characters
    # (including '$') in values are never expanded by the outer shell.
    cat > "$tmp_env" << 'ENVEOF'
# =============================================================================
# Buildkite Stack Controller — Environment Configuration
#
# Permissions: chmod 640  chown root:SERVICEUSER
# =============================================================================

# --- Required ----------------------------------------------------------------

ENVEOF
    # Stamp the generation date and service user without risking value expansion
    sed -i "s/SERVICEUSER/${SERVICE_USER}/" "$tmp_env"
    printf '# Generated by install.sh on %s\n#\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$tmp_env"

    printf 'BK_AGENT_TOKEN=%s\n' "${CFG[BK_AGENT_TOKEN]}"       >> "$tmp_env"
    printf 'BK_STACK_KEY=%s\n'   "${CFG[BK_STACK_KEY]}"         >> "$tmp_env"
    printf 'BK_AGENTAPI_BASE_URL=%s\n' "${CFG[BK_AGENTAPI_BASE_URL]}" >> "$tmp_env"

    cat >> "$tmp_env" << 'ENVEOF'

# --- Queue & concurrency -----------------------------------------------------

ENVEOF
    printf 'BK_QUEUE=%s\n'         "${CFG[BK_QUEUE]}"         >> "$tmp_env"
    printf 'BK_MAX_AGENTS=%s\n'    "${CFG[BK_MAX_AGENTS]}"    >> "$tmp_env"
    printf 'BK_POLL_INTERVAL=%s\n' "${CFG[BK_POLL_INTERVAL]}" >> "$tmp_env"
    printf 'BK_JOB_TIMEOUT=%s\n'   "${CFG[BK_JOB_TIMEOUT]}"   >> "$tmp_env"

    cat >> "$tmp_env" << 'ENVEOF'

# --- Paths -------------------------------------------------------------------

ENVEOF
    printf 'BK_WORK_DIR=%s\n' "${CFG[BK_WORK_DIR]}" >> "$tmp_env"
    printf 'BK_AGENT_TOKEN_FILE=%s\n' "${SECRETS_DIR}/agent-token" >> "$tmp_env"

    if [[ -n "${CFG[BK_GIT_MIRRORS_PATH]:-}" ]]; then
        printf 'BK_GIT_MIRRORS_PATH=%s\n' "${CFG[BK_GIT_MIRRORS_PATH]}" >> "$tmp_env"
    else
        printf '# BK_GIT_MIRRORS_PATH=\n' >> "$tmp_env"
    fi

    if [[ -n "${CFG[BK_CACHE_PATH]:-}" ]]; then
        printf 'BK_CACHE_PATH=%s\n' "${CFG[BK_CACHE_PATH]}" >> "$tmp_env"
    else
        printf '# BK_CACHE_PATH=\n' >> "$tmp_env"
    fi

    cat >> "$tmp_env" << 'EOF'

# --- SSH credentials ---------------------------------------------------------
# Only one of the following should be active at a time.
EOF

    if [[ -n "${CFG[BK_CREDENTIAL_SSH_KEY]:-}" ]]; then
        printf 'BK_CREDENTIAL_SSH_KEY=%s\n' "${CFG[BK_CREDENTIAL_SSH_KEY]}" >> "$tmp_env"
        printf '# BK_SSH_AGENT_SOCK=\n' >> "$tmp_env"
    elif [[ -n "${CFG[BK_SSH_AGENT_SOCK]:-}" ]]; then
        printf '# BK_CREDENTIAL_SSH_KEY=\n' >> "$tmp_env"
        printf 'BK_SSH_AGENT_SOCK=%s\n' "${CFG[BK_SSH_AGENT_SOCK]}" >> "$tmp_env"
    else
        printf '# BK_CREDENTIAL_SSH_KEY=\n' >> "$tmp_env"
        printf '# BK_SSH_AGENT_SOCK=\n' >> "$tmp_env"
    fi

    cat >> "$tmp_env" << 'ENVEOF'

# --- Extra agent environment -------------------------------------------------
# Uncomment and set a path to inject additional env vars into every agent unit.
# BK_EXTRA_ENV_FILE=/etc/bk-stack/agent-extra.env

# --- Logging -----------------------------------------------------------------

ENVEOF
    printf 'BK_LOG_LEVEL=%s\n' "${CFG[BK_LOG_LEVEL]}" >> "$tmp_env"

    run install -m 640 -o root -g "$SERVICE_USER" "$tmp_env" "$ENV_FILE"
    rm -f "$tmp_env"

    print_success "Configuration written to ${ENV_FILE}"
}

write_agent_config() {
    print_section "Writing agent configuration"

    if [[ -f "$AGENT_CONFIG_FILE" ]]; then
        print_info "Agent config already exists at ${AGENT_CONFIG_FILE} — skipping"
        return 0
    fi

    local tmp_cfg
    tmp_cfg=$(mktemp)

    cat > "$tmp_cfg" << 'AGENTCFGEOF'
# =============================================================================
# /etc/bk-stack/agent.cfg
#
# Shared buildkite-agent configuration for all transient agent units spawned
# by bk-stack-controller. This file must be world-readable (mode 644) so the
# ephemeral DynamicUser UID can read it.
#
# Do NOT add agent-token here — it is injected securely via LoadCredential.
# Dynamic per-job settings (queue, build path, tags) are set by the controller.
# =============================================================================

# Agents always disconnect after running a single job.
disconnect-after-job = true
no-color = true

# Optional: agent name template (%hostname expands to the host's hostname).
# name = "bk-%hostname-%n"

# Optional: hooks directory for environment and checkout hooks.
# hooks-path = /etc/bk-stack/hooks

# Optional: plugins directory.
# plugins-path = /etc/bk-stack/plugins
AGENTCFGEOF

    # World-readable so DynamicUser (random UID) can read it.
    run install -m 644 -o root -g root "$tmp_cfg" "$AGENT_CONFIG_FILE"
    rm -f "$tmp_cfg"

    print_success "Agent config written to ${AGENT_CONFIG_FILE}"
}

write_service_unit() {
    print_section "Installing systemd service unit"

    # Build optional BindReadOnlyPaths lines
    local bind_paths=""
    [[ -n "${CFG[BK_GIT_MIRRORS_PATH]:-}" ]] && bind_paths+=$'\n'"ReadWritePaths=${CFG[BK_GIT_MIRRORS_PATH]}"
    [[ -n "${CFG[BK_CACHE_PATH]:-}" ]]        && bind_paths+=$'\n'"ReadWritePaths=${CFG[BK_CACHE_PATH]}"

    # Build optional LoadCredential line
    local load_credential=""
    if [[ -n "${CFG[BK_CREDENTIAL_SSH_KEY]:-}" ]]; then
        load_credential="LoadCredential=ssh-key:${CFG[BK_CREDENTIAL_SSH_KEY]}"
    fi

    local tmp_svc
    tmp_svc=$(mktemp)

    cat > "$tmp_svc" << EOF
# =============================================================================
# ${SERVICE_NAME}.service
# Generated by install.sh on $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# =============================================================================

[Unit]
Description=Buildkite Stack Controller
Documentation=https://buildkite.com/docs/apis/agent-api/stacks
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${CONTROLLER_SCRIPT}
EnvironmentFile=${ENV_FILE}
${load_credential}

User=${SERVICE_USER}
Group=${SERVICE_USER}

ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
PrivateDevices=yes
NoNewPrivileges=yes
ReadWritePaths=${CFG[BK_WORK_DIR]}${bind_paths}

StandardOutput=journal
StandardError=journal
SyslogIdentifier=${SERVICE_NAME}

Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    run install -m 644 -o root -g root "$tmp_svc" "$SERVICE_FILE"
    rm -f "$tmp_svc"

    print_success "Service unit written to ${SERVICE_FILE}"
}

enable_and_start_service() {
    print_section "Enabling and starting service"

    run systemctl daemon-reload
    print_step "Daemon reloaded"

    run systemctl enable "$SERVICE_NAME"
    print_success "Service enabled (starts on boot)"

    run systemctl start "$SERVICE_NAME"
    print_success "Service started"

    # Brief pause then check status
    if [[ "$DRY_RUN" -eq 0 ]]; then
        sleep 2
        if systemctl is-active --quiet "$SERVICE_NAME"; then
            print_success "Service is running"
        else
            print_warn "Service may not have started correctly. Check logs with:"
            echo "    journalctl -u ${SERVICE_NAME} -n 50 --no-pager"
        fi
    fi
}

# =============================================================================
# Uninstall
# =============================================================================

uninstall() {
    print_section "Uninstalling Buildkite Stack Controller"

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_step "Stopping service..."
        run systemctl stop "$SERVICE_NAME"
    fi

    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        print_step "Disabling service..."
        run systemctl disable "$SERVICE_NAME"
    fi

    for f in "$SERVICE_FILE" "$CONTROLLER_SCRIPT" "$POLKIT_RULES_FILE"; do
        if [[ -f "$f" ]]; then
            run rm -f "$f"
            print_step "Removed $f"
        fi
    done

    run systemctl daemon-reload

    echo
    print_warn "The following were NOT removed (may contain your data / secrets):"
    echo "    ${CONFIG_DIR}  (agent token, SSH keys)"
    echo "    ${CFG[BK_WORK_DIR]:-$WORK_DIR}  (build workspaces)"
    echo
    yes_no "purge_config" "Remove config directory ${CONFIG_DIR} as well?" "n"
    if [[ "${CFG[purge_config]}" == "y" ]]; then
        run rm -rf "$CONFIG_DIR"
        print_step "Removed ${CONFIG_DIR}"
    fi

    print_success "Uninstall complete"
}

# =============================================================================
# Post-install summary
# =============================================================================

print_post_install() {
    print_section "Installation complete"
    echo
    echo "  ${BOLD}Service management${RESET}"
    echo "    ${DIM}Status:${RESET}   systemctl status ${SERVICE_NAME}"
    echo "    ${DIM}Logs:${RESET}     journalctl -u ${SERVICE_NAME} -f"
    echo "    ${DIM}Stop:${RESET}     systemctl stop ${SERVICE_NAME}"
    echo "    ${DIM}Restart:${RESET}  systemctl restart ${SERVICE_NAME}"
    echo
    echo "  ${BOLD}Configuration${RESET}"
    echo "    ${DIM}Edit:${RESET}     ${ENV_FILE}"
    echo "    ${DIM}Apply:${RESET}    systemctl restart ${SERVICE_NAME}"
    echo
    echo "  ${BOLD}Uninstall${RESET}"
    echo "    ${DIM}Run:${RESET}      sudo bash $0 --uninstall"
    echo

    if [[ -n "${CFG[BK_CREDENTIAL_SSH_KEY]:-}" && -f "${CFG[BK_CREDENTIAL_SSH_KEY]}.pub" ]]; then
        echo "  ${BOLD}${YELLOW}Reminder:${RESET} Ensure this public key is added as a deploy key"
        echo "  on your git hosting provider if you haven't done so already."
        echo
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    parse_args "$@"
    print_header

    if [[ "$UNINSTALL" -eq 1 ]]; then
        check_root
        # Populate CFG with defaults so uninstall paths work
        CFG[BK_WORK_DIR]="$WORK_DIR"
        uninstall
        exit 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        print_warn "DRY RUN mode — no changes will be made"
    fi

    check_root
    check_os
    check_dependencies

    # Collect configuration
    collect_required_config
    collect_queue_config
    collect_paths_config
    collect_ssh_config
    collect_logging_config
    review_config

    # Install
    install_polkit_rule
    create_user
    create_directories
    write_agent_token_file
    generate_ssh_key
    install_controller_script
    write_env_file
    write_agent_config
    write_service_unit
    enable_and_start_service

    print_post_install
}

main "$@"
