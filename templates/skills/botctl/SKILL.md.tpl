---
name: botctl
description: "Trigger immediately when a user message contains BOTCTL_URL:, BOTCTL_FILE:, or BOTCTL: near the start. Execute __OPENCLAW_WORKSPACE__/scripts/openclaw-bot-lifecycle/botctl_local.py directly, never use sessions_spawn/subagents, and never invoke a generic botctl CLI."
metadata: {"openclaw":{"always":true}}
---

# BOTCTL Trigger

Use this skill when the user message contains `BOTCTL_URL:`, `BOTCTL_FILE:`, or `BOTCTL:` near the beginning.

OpenClaw may prepend a timestamp prefix before the actual message text. Ignore that prefix when extracting the payload.

## Required behavior

1. Do not reply that a command is missing.
2. Do not search for a slash command named `openclaw-bot-lifecycle`.
3. Do not search for a shell command named `openclaw-bot-lifecycle`.
4. Treat the message as a standardized bot lifecycle payload.
5. If the message contains `BOTCTL_URL:`, extract the exact bundle URL after the first `BOTCTL_URL:` marker and execute:

```bash
__OPENCLAW_WORKSPACE__/scripts/openclaw-bot-lifecycle/botctl_local.py --bundle-url "<exact-url>"
```

6. If the message does not contain `BOTCTL_URL:` but contains `BOTCTL_FILE:`, extract the exact payload file path and execute:

```bash
__OPENCLAW_WORKSPACE__/scripts/openclaw-bot-lifecycle/botctl_local.py "<exact-payload-file>"
```

7. If the message contains only `BOTCTL:`, parse the JSON after the first marker and write it to a temporary file under `/tmp/`, then execute the helper with that file.
8. Never run the helper without exactly one input source.
9. Never run the helper in the background.
10. Wait for the helper to finish and return its stdout exactly as the final answer.
11. Never use `sessions_spawn`, subagents, or delegation for BOTCTL handling.
12. Never execute a shell command named `botctl`; the installed helper script is the only valid command path.

## Execution note

- Execute the helper script directly.
- Do **not** wrap it with `python3 ...`.
- This is required so script-path allowlists can match reliably for `create`, `publish`, `activate`, and `delete`.

## Local environment assumptions

- current main management agent id is `__MAIN_AGENT_ID__`
- main workspace is `__OPENCLAW_WORKSPACE__`
- helper path is `__OPENCLAW_WORKSPACE__/scripts/openclaw-bot-lifecycle/botctl_local.py`
