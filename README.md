# OpenClaw BOTCTL Kit

Minimal installation kit for running `BOTCTL_URL`, `BOTCTL_FILE`, and `BOTCTL` lifecycle commands on another OpenClaw main agent.

This kit installs:

- `skills/botctl/SKILL.md`
- `skills/openclaw-bot-lifecycle/SKILL.md`
- `scripts/openclaw-bot-lifecycle/botctl_local.py`

## What It Solves

Use this when `developer` needs to control another OpenClaw instance with the smallest possible remote footprint.

The remote side only needs:

- the two skills
- the local helper script
- Python 3
- local filesystem access to its own OpenClaw state

## Install

Run:

```bash
./install.sh \
  --workspace "/path/to/openclaw-workspace" \
  --main-agent-id "dev"
```

If `--state-root` is omitted, the installer defaults to the workspace parent directory.

Example:

```bash
./install.sh \
  --workspace "$HOME/.openclaw/workspace" \
  --main-agent-id "main"
```

If you want to pass it explicitly, use the same state root your gateway is actually reading:

```bash
./install.sh \
  --workspace "$HOME/.openclaw/workspace" \
  --state-root "$HOME/.openclaw" \
  --main-agent-id "main"
```

## Internal Versioning

Recommended internal usage:

- push this repository to GitHub
- create tags such as `v0.1.0`
- let teammates download a fixed tag or release zip instead of the moving default branch

## Installed Paths

After install, the target OpenClaw instance will contain:

```text
<workspace>/skills/botctl/SKILL.md
<workspace>/skills/openclaw-bot-lifecycle/SKILL.md
<workspace>/scripts/openclaw-bot-lifecycle/botctl_local.py
```

## Required Inputs From Developer

The `developer` service should send one of:

- `BOTCTL_URL: <signed-bundle-url>`
- `BOTCTL_FILE: <payload-file>`
- `BOTCTL: <inline-json>`

`BOTCTL_URL` is preferred.

## Notes

- This kit does not create a database.
- Bundles downloaded through `--bundle-url` are unpacked into a temporary directory and deleted after execution.
- The `developer` side is still responsible for generating signed bundle URLs and lifecycle payloads.
- Running `install.sh` will overwrite the installed skill and helper files at the target paths.
- `--state-root` must point to the same OpenClaw state root your gateway is using, typically `~/.openclaw`.
- For Zapry / `openapi` bots, `create` now provisions `channels.zapry.accounts.<botId>` and the matching `bindings` route so polling can start before later publish/activate steps.

## Validate Quickly

After installation, ask the remote OpenClaw main agent to process a `BOTCTL_URL:` message. If the helper runs and returns:

```text
Action: activate
Bot: <botId>
Status: activated
```

then the bridge is wired correctly.

For Zapry / `openapi` bots, you can also validate after `create` that:

- `channels.zapry.accounts.<botId>` exists in `openclaw.json`
- a `bindings` route exists from account `<botId>` to agent `<tenantId>-<botId>`
