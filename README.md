# buildkite-agent-systemd-stack

Run on-demand, isolated Buildkite agents on a bare Linux host using the [Buildkite Stacks API](https://buildkite.com/docs/apis/agent-api/stacks) and systemd — no containers required.

Each job gets its own transient systemd unit with an ephemeral user, private filesystem, and resource limits. When the job finishes the unit is gone. If you're already familiar with Buildkite and just want to get running, jump to [Quick Start](#quick-start).

## How it works

A persistent controller service (`bk-stack-controller`) registers with a Buildkite cluster queue and polls the Stacks API for scheduled jobs. When a job is available it atomically reserves it (preventing double-dispatch if multiple controller instances are running) and spawns a transient `bk-agent-<uuid>.service` unit via `systemd-run`. Each unit runs under an ephemeral UID (`DynamicUser=yes`) with private tmp, no new privileges, memory and CPU limits, and a configurable wall-clock timeout — all cleaned up automatically on exit. The Buildkite agent token is injected via `LoadCredential` so it never appears in environment variables or `systemctl show` output.

## Prerequisites

- Linux with **systemd 247+** (Ubuntu 22.04+, Debian 12+, RHEL 9+)
- [`buildkite-agent`](https://buildkite.com/docs/agent/v3/installation) installed on the host
- `curl` and `jq`
- Root access for the installer

## Quick Start

```bash
sudo bash install.sh
```

The installer is interactive and walks through all configuration. Two useful flags:

```bash
sudo bash install.sh --dry-run      # preview all changes without applying them
sudo bash install.sh --unattended   # non-interactive; reads config from environment variables
```

After installation, the controller writes a config file at `/etc/bk-stack/controller.env`. The three required variables are:

```bash
BK_AGENT_TOKEN=<your-buildkite-cluster-agent-token>
BK_STACK_KEY=<unique-name-for-this-host>        # e.g. prod-linux-01-stack
BK_AGENTAPI_BASE_URL=https://agent.buildkite.com/v3
```

## Service management

```bash
systemctl status bk-stack-controller
journalctl -u bk-stack-controller -f

# After editing /etc/bk-stack/controller.env:
systemctl restart bk-stack-controller

# Uninstall:
sudo bash install.sh --uninstall
```

## Configuration

The most commonly adjusted variables:

| Variable | Default | Description |
|---|---|---|
| `BK_MAX_AGENTS` | `4` | Maximum concurrent job units |
| `BK_QUEUE` | `default` | Buildkite cluster queue to serve |
| `BK_POLL_INTERVAL` | `5` | Seconds between Stacks API polls |
| `BK_JOB_TIMEOUT` | `3600` | Max seconds a job unit may run before being killed |
| `BK_GIT_MIRRORS_PATH` | — | Shared bare-repo git mirror cache (speeds up clones) |
| `BK_LOG_LEVEL` | `info` | `debug` \| `info` \| `warn` \| `error` |

See [`controller.env.example`](controller.env.example) for the full list, including SSH credential options.
