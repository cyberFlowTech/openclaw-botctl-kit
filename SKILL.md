---
name: openclaw-botctl-kit
description: Installs BOTCTL_URL and BOTCTL_FILE lifecycle skills plus a local helper for OpenClaw. Use when packaging or installing the standardized botctl bridge onto another OpenClaw instance.
---

# OpenClaw BOTCTL Kit

This repository packages the minimum remote-side files needed for `developer` to drive another OpenClaw main agent through standardized lifecycle commands.

## What This Skill Provides

After installation, the target OpenClaw environment gets:

- `skills/botctl/SKILL.md`
- `skills/openclaw-bot-lifecycle/SKILL.md`
- `scripts/openclaw-bot-lifecycle/botctl_local.py`

## Install

Run:

```bash
./install.sh \
  --workspace "/path/to/openclaw-workspace" \
  --state-root "/path/to/openclaw-state-root" \
  --main-agent-id "dev"
```

## Intended Use

Use this kit when:

- another OpenClaw instance needs to receive `BOTCTL_URL`
- the remote side should stay lightweight
- the team wants a versioned installable package from GitHub

## Notes

- Python 3 is required on the remote side.
- The helper deletes downloaded bundle temp files after execution.
- `developer` remains responsible for generating bundle URLs and lifecycle payloads.
