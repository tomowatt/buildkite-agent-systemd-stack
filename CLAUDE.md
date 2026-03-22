# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Core Rules

Do NOT make code edits unless explicitly asked. When investigating or answering questions, stick to read-only operations (Read, Grep, Glob) unless the user requests changes.

## Investigation Guidelines

When investigating issues, always confirm which specific feature/system the user is asking about before diving into code analysis. Ask clarifying questions if the request is ambiguous (e.g., 'Buildkite Agent hooks' vs 'Claude Code hooks', controller behaviour vs agent unit behaviour).

## Debugging

When debugging deployment or infrastructure issues, verify each fix against the actual error before moving to the next step. Don't assume the first hypothesis is correct — validate with logs or reproduction.

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
  └─ writes /etc/polkit-1/rules.d/50-bk-stack.rules  (mode 644)
  └─ writes /etc/bk-stack/controller.env              (mode 640, root:bk-stack)
  └─ writes /etc/bk-stack/agent.cfg                   (mode 644, world-readable)
  └─ writes /etc/bk-stack/secrets/agent-token         (mode 400, root:root)
  └─ writes /etc/systemd/system/bk-stack-controller.service
  └─ systemctl enable --now bk-stack-controller

bk-stack-controller.sh (runs as bk-stack user)
  └─ register_stack()       → POST /stacks/register
                              { key, type: "custom", queue_key, metadata: { version, hostname } }
  └─ poll loop every BK_POLL_INTERVAL seconds:
       get_scheduled_jobs() → GET /stacks/{key}/scheduled-jobs?queue_key=...&limit=BK_MAX_AGENTS
                              response includes cluster_queue.dispatch_paused
       reserve_jobs_batch() → PUT /stacks/{key}/scheduled-jobs/batch-reserve
                              { job_uuids: [...], reservation_expiry_seconds: min(BK_JOB_TIMEOUT, 3600) }
       for each reserved job (priority order, up to available slots):
         spawn_agent()      → systemd-run transient unit
```

### Per-job isolation

Each job runs in a transient `bk-agent-<uuid>.service` unit with:
- `DynamicUser=yes` — ephemeral UID, auto-cleaned on exit
- `PrivateTmp`, `PrivateDevices`, `ProtectHome`, `NoNewPrivileges`
- `MemoryMax=4G`, `CPUQuota=200%`, `TasksMax=512`, `RuntimeMaxSec=<BK_JOB_TIMEOUT>`
- Agent token injected via `LoadCredential=agent-token:<BK_AGENT_TOKEN_FILE>` — never in `Environment=` or on the command line
- Agent config passed via `--config "$_BK_AGENT_CFG"` pointing to `/etc/bk-stack/agent.cfg` (mode 644, world-readable for the ephemeral UID)
- The agent command is a multi-line `bash -c` heredoc that: (1) sets up `libnss-wrapper` so `getpwuid()` resolves for the ephemeral UID (fixes SSH "No user exists" errors), (2) starts a per-job `ssh-agent` and loads `$CREDENTIALS_DIRECTORY/ssh-key` if present, (3) reads the agent token from `$CREDENTIALS_DIRECTORY/agent-token` and exec-s `buildkite-agent start`

### Key design constraints

**`systemd-run` arg construction** — built as a bash array, never a string, to avoid quoting pitfalls with directory paths.

**Token security** — `BK_AGENT_TOKEN` is used by the controller for its own API calls (read from `EnvironmentFile`). For agent units, the token travels via `LoadCredential` referencing `/etc/bk-stack/secrets/agent-token` (file, mode 400) so it never appears in `systemctl show` output or `/proc/<pid>/cmdline`.

**polkit rule** — `systemd-run` uses D-Bus to talk to PID 1; polkit controls access via `org.freedesktop.systemd1.manage-units`. `/etc/polkit-1/rules.d/50-bk-stack.rules` grants the `bk-stack` user unconditional YES on that action. `CAP_SYS_ADMIN` is not used — polkit checks UID, not Linux capabilities.

**Agent config file** — `/etc/bk-stack/agent.cfg` is world-readable (644) so the `DynamicUser` ephemeral UID can read it. It must NOT contain the agent token. Dynamic per-job values (`_BK_QUEUE`, `_BK_AGENT_CFG`, `BUILDKITE_AGENT_ACQUIRE_JOB`) are injected as `Environment=` properties on the unit.

**Batch reservation** — `reserve_jobs_batch()` issues a single `PUT` to `batch-reserve` for all candidate UUIDs. The response's `reserved` array is filtered to determine which jobs to spawn. Jobs not in `reserved` were claimed by another controller instance.

**Single API call per poll cycle** — `get_scheduled_jobs()` returns `dispatch_paused` in `cluster_queue.dispatch_paused` alongside the jobs array, eliminating a separate status call.

**Multi-instance safety** — `reserve_jobs_batch()` is atomic on the server side. Only one controller instance will receive a given UUID in its `reserved` response.

**Graceful shutdown** — `SIGTERM` sets a flag; the poll loop exits cleanly, then `wait_for_agents()` blocks until all in-flight units finish (or `BK_JOB_TIMEOUT` elapses).

**Interruptible sleep** — `sleep N & wait $!` so signals wake the controller immediately rather than waiting out the full poll interval.

**Self-update** — `sudo bk-stack-controller.sh --update` downloads the latest script, syntax-checks it, compares versions, and replaces the binary via `install`. The `--update` path runs before the EnvironmentFile is loaded; all required vars have empty-string defaults to satisfy `set -u`.

### SSH credential options (chosen at install time)

- **Method A** — `LoadCredential`: SSH key injected per-unit, only visible inside that unit's process tree. Controlled by `BK_CREDENTIAL_SSH_KEY`.
- **Method B** — shared `ssh-agent` socket: simpler, all concurrent jobs share one agent. Controlled by `BK_SSH_AGENT_SOCK`.
- **Method C** — none; configure via agent environment hooks.

## Known gaps

- No retry/backoff on API calls — transient failures are retried at the next poll interval.
- No pagination for the scheduled-jobs response; `limit=BK_MAX_AGENTS` is used (well within the API's 1000-job maximum).

## systemd version requirement

Minimum systemd **247** (for `SetCredential`/`LoadCredential` on transient units). The installer warns if the detected version is below this threshold.
