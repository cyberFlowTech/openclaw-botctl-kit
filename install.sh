#!/usr/bin/env bash
set -euo pipefail

WORKSPACE=""
STATE_ROOT=""
MAIN_AGENT_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      WORKSPACE="${2:-}"
      shift 2
      ;;
    --state-root)
      STATE_ROOT="${2:-}"
      shift 2
      ;;
    --main-agent-id)
      MAIN_AGENT_ID="${2:-}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$WORKSPACE" || -z "$MAIN_AGENT_ID" ]]; then
  echo "Usage: ./install.sh --workspace <workspace> [--state-root <state-root>] --main-agent-id <agent-id>" >&2
  exit 1
fi

if [[ -z "$STATE_ROOT" ]]; then
  STATE_ROOT="$(cd "$(dirname "$WORKSPACE")" && pwd)"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BOTCTL_TARGET="$WORKSPACE/skills/botctl/SKILL.md"
LIFECYCLE_TARGET="$WORKSPACE/skills/openclaw-bot-lifecycle/SKILL.md"
HELPER_TARGET="$WORKSPACE/scripts/openclaw-bot-lifecycle/botctl_local.py"

mkdir -p "$(dirname "$BOTCTL_TARGET")" "$(dirname "$LIFECYCLE_TARGET")" "$(dirname "$HELPER_TARGET")"

python3 - "$SCRIPT_DIR" "$WORKSPACE" "$STATE_ROOT" "$MAIN_AGENT_ID" "$BOTCTL_TARGET" "$LIFECYCLE_TARGET" "$HELPER_TARGET" <<'PY'
from pathlib import Path
import sys

script_dir = Path(sys.argv[1])
workspace = sys.argv[2]
state_root = sys.argv[3]
main_agent_id = sys.argv[4]
targets = [Path(p) for p in sys.argv[5:8]]

mapping = {
    "__OPENCLAW_WORKSPACE__": workspace,
    "__OPENCLAW_STATE_ROOT__": state_root,
    "__MAIN_AGENT_ID__": main_agent_id,
}

sources = [
    script_dir / "templates" / "skills" / "botctl" / "SKILL.md.tpl",
    script_dir / "templates" / "skills" / "openclaw-bot-lifecycle" / "SKILL.md.tpl",
    script_dir / "templates" / "scripts" / "openclaw-bot-lifecycle" / "botctl_local.py.tpl",
]

for source, target in zip(sources, targets):
    content = source.read_text(encoding="utf-8")
    for key, value in mapping.items():
        content = content.replace(key, value)
    target.write_text(content, encoding="utf-8")
PY

chmod +x "$HELPER_TARGET"

echo "Installed BOTCTL kit:"
echo "  workspace: $WORKSPACE"
echo "  state root: $STATE_ROOT"
echo "  main agent: $MAIN_AGENT_ID"
echo "  botctl skill: $BOTCTL_TARGET"
echo "  lifecycle skill: $LIFECYCLE_TARGET"
echo "  helper: $HELPER_TARGET"
