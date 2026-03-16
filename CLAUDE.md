# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Linux-native Buildkite agent orchestration system using the Buildkite Stacks API and systemd. The controller runs as a persistent daemon, polls for scheduled jobs, and spawns one transient systemd unit per job — no Docker or Kubernetes involved.

## Files

| File | Purpose |
|------|---------|
| `bk-stack-controller.sh` | Controller daemon — poll loop, job reservation, agent unit spawning |
| `bk-stack-controller.service` | Static systemd unit template (for manual installs) |
| `install.sh` | Interactive installer; also supports `--unattended` and `--dry-run` |
| `controller.env.example` | Annotated reference for all environment variables |

## Testing changes

There is no automated test suite. Validate changes with:

```bash
# Syntax check
bash -n bk-stack-controller.sh
bash -n install.sh

# ShellCheck (install via: apt-get install shellcheck / brew install shellcheck)
shellcheck bk-stack-controller.sh
shellcheck install.sh

# Dry-run the installer (no changes made to the system)
sudo bash install.sh --dry-run
```

To test the controller without a real Buildkite cluster, set the env vars manually and run with `BK_LOG_LEVEL=debug`.

## Architecture

### Control flow

```
install.sh
  └─ writes /etc/bk-stack/controller.env        (mode 640, root:bk-stack)
  └─ writes /etc/bk-stack/secrets/agent-token   (mode 400, root:root)
  └─ writes /etc/systemd/system/bk-stack-controller.service
  └─ systemctl enable --now bk-stack-controller

bk-stack-controller.sh (runs as bk-stack user)
  └─ register_stack()     → POST /stacks/register
  └─ poll loop every BK_POLL_INTERVAL seconds:
       dispatch_paused?  → GET /stacks/{key}
       get_scheduled_jobs → GET /stacks/{key}/scheduled-jobs
       for each job (sorted by priority desc, up to available slots):
         reserve_job()   → POST /stacks/{key}/reserve-jobs  (atomic, idempotent)
         spawn_agent()   → systemd-run transient unit
```

### Per-job isolation

Each job runs in a transient `bk-agent-<uuid>.service` unit with:
- `DynamicUser=yes` — ephemeral UID, auto-cleaned on exit
- `PrivateTmp`, `PrivateDevices`, `ProtectHome`, `NoNewPrivileges`
- `MemoryMax=4G`, `CPUQuota=200%`, `TasksMax=512`, `RuntimeMaxSec=<BK_JOB_TIMEOUT>`
- Agent token injected via `LoadCredential=agent-token:<BK_AGENT_TOKEN_FILE>` — never in `Environment=` or on the command line
- The agent command is a `bash -c` wrapper that reads the token from `$CREDENTIALS_DIRECTORY/agent-token` before exec-ing `buildkite-agent start`

### Key design constraints

**`systemd-run` arg construction** — built as a bash array, never a string, to avoid quoting pitfalls with directory paths.

**Token security** — `BK_AGENT_TOKEN` is used by the controller for its own API calls (read from `EnvironmentFile`). For agent units, the token travels via `LoadCredential` referencing `/etc/bk-stack/secrets/agent-token` (file, mode 400) so it never appears in `systemctl show` output or `/proc/<pid>/cmdline`.

**Multi-instance deduplication** — `reserve_job()` POSTs to the reserve-jobs endpoint before spawning. A non-200 response means another controller instance claimed the job; skip it.

**Graceful shutdown** — `SIGTERM` sets a flag; the poll loop exits cleanly, then `wait_for_agents()` blocks until all in-flight units finish (or `BK_JOB_TIMEOUT` elapses).

**Interruptible sleep** — `sleep N & wait $!` so signals wake the controller immediately rather than waiting out the full poll interval.

### SSH credential options (chosen at install time)

- **Method A** — `LoadCredential`: SSH key injected per-unit, only visible inside that unit's process tree. Controlled by `BK_CREDENTIAL_SSH_KEY`.
- **Method B** — shared `ssh-agent` socket: simpler, all concurrent jobs share one agent. Controlled by `BK_SSH_AGENT_SOCK`.
- **Method C** — none; configure via agent environment hooks.

## Known gaps

- `CONTROLLER_SCRIPT_URL` in `install.sh` contains a `YOUR_ORG/YOUR_REPO` placeholder — update before publishing.
- No agent environment hook is provided for wiring `$CREDENTIALS_DIRECTORY/ssh-key` into ssh-agent (SSH method A); this must be supplied separately.
- No retry/backoff on API calls — transient failures are retried at the next poll interval.
- `dispatch_paused` check makes an extra API call per cycle; could be folded into the scheduled-jobs response.

## systemd version requirement

Minimum systemd **247** (for `SetCredential`/`LoadCredential` on transient units). The installer warns if the detected version is below this threshold.
