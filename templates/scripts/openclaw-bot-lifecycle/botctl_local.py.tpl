#!/usr/bin/env python3
import argparse
import json
import shutil
import tempfile
import urllib.request
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4


WORKSPACE_ROOT = Path("__OPENCLAW_WORKSPACE__")
MANAGED_BOTS_ROOT = WORKSPACE_ROOT / "managed-bots"
OPENCLAW_STATE_ROOT = Path("__OPENCLAW_STATE_ROOT__")
OPENCLAW_CONFIG_PATH = OPENCLAW_STATE_ROOT / "openclaw.json"
CURRENT_AGENT_ID = "__MAIN_AGENT_ID__"


def now_rfc3339() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def now_ms() -> int:
    return int(datetime.now(timezone.utc).timestamp() * 1000)


def ensure(condition: bool, reason: str) -> None:
    if not condition:
        raise ValueError(reason)


def load_payload(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def load_json(path: Path, fallback):
    if not path.exists():
        return fallback
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path: Path, content) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(content, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def clean_abs(path_str: str, base_dir: Path | None = None) -> Path:
    path_value = Path(path_str).expanduser()
    if not path_value.is_absolute():
        path_value = (base_dir or Path.cwd()) / path_value
    return path_value.resolve()


def ensure_under(path_value: Path, roots: list[Path], reason: str) -> None:
    ensure(any(path_value.is_relative_to(root) for root in roots), reason)


def compact_summary(action: str, bot_id: str, status: str, version: str, summary: str) -> None:
    print(
        "\n".join(
            [
                f"Action: {action}",
                f"Bot: {bot_id}",
                f"Status: {status}",
                f"Version: {version}",
                f"Summary: {summary}",
            ]
        )
    )


def validate(payload: dict) -> tuple[str, dict, dict, dict]:
    ensure(payload.get("protocol") == "botctl/v1", "protocol must be botctl/v1")
    skill = payload.get("skill") or {}
    ensure(skill.get("name") == "openclaw-bot-lifecycle", "skill.name must be openclaw-bot-lifecycle")
    action = str(skill.get("action") or "").strip()
    ensure(action in {"create", "publish", "delete", "activate"}, "action must be create, publish, delete, or activate")

    invocation = payload.get("invocation") or {}
    security = payload.get("security") or {}
    target = payload.get("target") or {}
    inputs = payload.get("inputs") or {}

    ensure(invocation.get("prefix") == "BOTCTL:", "invocation.prefix must be BOTCTL:")
    ensure(bool(invocation.get("mainOnly")), "invocation.mainOnly must be true")
    ensure(bool(security.get("mainOnly")), "security.mainOnly must be true")
    ensure(bool(security.get("refuseIfNotMain")), "security.refuseIfNotMain must be true")
    ensure(target.get("openclawMode") == "standardized", "target.openclawMode must be standardized")
    ensure(target.get("mainAgentId") == CURRENT_AGENT_ID, "target.mainAgentId does not match current main agent")
    ensure(invocation.get("targetAgentId") == CURRENT_AGENT_ID, "invocation.targetAgentId does not match current main agent")

    bot = inputs.get("bot") or {}
    bot_id = str(bot.get("botId") or "").strip()
    ensure(bot_id != "", "inputs.bot.botId is required")

    return action, bot, inputs, security


def bot_root(bot_id: str) -> Path:
    return MANAGED_BOTS_ROOT / bot_id


def touch_meta(cfg: dict) -> None:
    meta = cfg.setdefault("meta", {})
    meta["lastTouchedAt"] = now_rfc3339()


def channel_name(platform_type: str) -> str:
    return "telegram" if platform_type == "telegram" else ""


def supports_channel_config(platform_type: str) -> bool:
    return channel_name(platform_type) != ""


def agent_id_for(bot_id: str, tenant_id: str) -> str:
    tenant = str(tenant_id or "").strip()
    return f"{tenant}-{bot_id}" if tenant else bot_id


def ensure_agent_support_files(agent_id: str) -> Path:
    agent_root = OPENCLAW_STATE_ROOT / "agents" / agent_id / "agent"
    agent_root.mkdir(parents=True, exist_ok=True)
    return agent_root


def managed_provider_id(agent_id: str) -> str:
    return f"managed-openai-{agent_id}"


def managed_model_id(model_name: str) -> str:
    normalized = str(model_name or "").strip().lower()
    if "/" in normalized:
        return normalized.split("/", 1)[1]
    return normalized


def managed_primary_model(agent_id: str, model_name: str) -> str:
    model_id = managed_model_id(model_name)
    provider_id = managed_provider_id(agent_id)
    return f"{provider_id}/{model_id}" if model_id else f"{provider_id}/missing-model"


def model_inputs_for(model_id: str) -> list[str]:
    normalized = str(model_id or "").strip().lower()
    if normalized.startswith(("gpt-4.1", "gpt-4o", "gpt-5", "o1", "o3", "o4")):
        return ["text", "image"]
    return ["text"]


def sync_managed_model_config(agent_dir: Path, agent_id: str, bot: dict) -> str:
    model_name = str(bot.get("modelName") or "").strip()
    model_api_key = str(bot.get("modelApiKey") or "").strip()
    model_api_base_url = str(bot.get("modelApiBaseUrl") or "").strip()
    model_id = managed_model_id(model_name)
    provider_id = managed_provider_id(agent_id)
    ensure(model_api_key != "", "bot modelApiKey is required for activation")
    ensure(model_api_base_url != "", "bot modelApiBaseUrl is required for activation")
    ensure(model_id != "", "bot modelName is required for activation")
    write_json(
        agent_dir / "auth-profiles.json",
        {
            "profiles": {
                f"{provider_id}:default": {
                    "type": "api_key",
                    "provider": provider_id,
                    "key": model_api_key,
                }
            }
        },
    )
    write_json(
        agent_dir / "models.json",
        {
            "providers": {
                provider_id: {
                    "baseUrl": model_api_base_url,
                    "apiKey": model_api_key,
                    "api": "openai-responses",
                    "authHeader": True,
                    "models": [
                        {
                            "id": model_id,
                            "name": model_name,
                            "input": model_inputs_for(model_id),
                        }
                    ],
                }
            }
        },
    )
    return managed_primary_model(agent_id, model_name)


def ensure_workspace_copy(agent_id: str, source_dir: Path) -> Path:
    target_dir = OPENCLAW_STATE_ROOT / f"workspace-{agent_id}"
    if target_dir.exists():
        shutil.rmtree(target_dir)
    shutil.copytree(source_dir, target_dir)
    return target_dir


def upsert_agent(cfg: dict, *, agent_id: str, name: str, workspace_dir: Path, agent_dir: Path, primary_model: str) -> None:
    agents = cfg.setdefault("agents", {})
    current = agents.setdefault("list", [])
    next_list = [item for item in current if str(item.get("id") or "").strip() != agent_id]
    next_agent = {
        "id": agent_id,
        "name": name or agent_id,
        "workspace": str(workspace_dir.resolve()),
        "agentDir": str(agent_dir.resolve()),
    }
    normalized_model = str(primary_model or "").strip()
    if normalized_model:
        next_agent["model"] = {"primary": normalized_model}
    next_list.append(next_agent)
    agents["list"] = next_list


def remove_agent(cfg: dict, *, agent_id: str) -> bool:
    agents = cfg.get("agents") or {}
    current = agents.get("list") or []
    next_list = [item for item in current if str(item.get("id") or "").strip() != agent_id]
    changed = len(next_list) != len(current)
    if next_list:
        agents["list"] = next_list
        cfg["agents"] = agents
    elif "list" in agents:
        del agents["list"]
        if agents:
            cfg["agents"] = agents
        elif "agents" in cfg:
            del cfg["agents"]
    return changed


def upsert_route(cfg: dict, *, channel: str, account_id: str, agent_id: str) -> None:
    current = cfg.setdefault("bindings", [])
    next_bindings = []
    for item in current:
        match = item.get("match") or {}
        if item.get("type") == "route" and str(match.get("channel") or "").strip().lower() == channel and str(match.get("accountId") or "").strip() == account_id:
            continue
        next_bindings.append(item)
    next_bindings.append(
        {
            "type": "route",
            "agentId": agent_id,
            "comment": f"managed by openclaw-bot-lifecycle ({channel})",
            "match": {"channel": channel, "accountId": account_id},
        }
    )
    cfg["bindings"] = next_bindings


def remove_channel_account_and_route(cfg: dict, *, channel: str, account_id: str) -> None:
    channels = cfg.get("channels") or {}
    channel_cfg = channels.get(channel) or {}
    accounts = channel_cfg.get("accounts") or {}
    if account_id in accounts:
        del accounts[account_id]
    if accounts:
        channel_cfg["accounts"] = accounts
        channels[channel] = channel_cfg
    elif channel in channels:
        del channels[channel]
    if channels:
        cfg["channels"] = channels
    elif "channels" in cfg:
        del cfg["channels"]

    current = cfg.get("bindings") or []
    next_bindings = []
    for item in current:
        match = item.get("match") or {}
        if item.get("type") == "route" and str(match.get("channel") or "").strip().lower() == channel and str(match.get("accountId") or "").strip() == account_id:
            continue
        next_bindings.append(item)
    if next_bindings:
        cfg["bindings"] = next_bindings
    elif "bindings" in cfg:
        del cfg["bindings"]


def remove_account_references(cfg: dict, *, account_id: str, agent_id: str) -> bool:
    changed = False
    channels = cfg.get("channels") or {}
    next_channels = {}
    for channel_name_value, channel_cfg in channels.items():
        channel_cfg = channel_cfg or {}
        accounts = dict((channel_cfg.get("accounts") or {}))
        if account_id in accounts:
            del accounts[account_id]
            changed = True
        if accounts:
            next_channel_cfg = dict(channel_cfg)
            next_channel_cfg["accounts"] = accounts
            next_channels[channel_name_value] = next_channel_cfg
        elif channel_cfg and "accounts" in channel_cfg:
            next_channel_cfg = dict(channel_cfg)
            del next_channel_cfg["accounts"]
            if next_channel_cfg:
                next_channels[channel_name_value] = next_channel_cfg
            else:
                changed = True
        elif channel_cfg:
            next_channels[channel_name_value] = channel_cfg
    if next_channels:
        cfg["channels"] = next_channels
    elif "channels" in cfg:
        del cfg["channels"]
        changed = True

    current_bindings = cfg.get("bindings") or []
    next_bindings = []
    for item in current_bindings:
        match = item.get("match") or {}
        if str(item.get("agentId") or "").strip() == agent_id:
            changed = True
            continue
        if item.get("type") == "route" and str(match.get("accountId") or "").strip() == account_id:
            changed = True
            continue
        next_bindings.append(item)
    if next_bindings:
        cfg["bindings"] = next_bindings
    elif "bindings" in cfg:
        del cfg["bindings"]
        changed = True

    return changed


def upsert_channel_account(cfg: dict, *, platform_type: str, bot: dict) -> None:
    channel = channel_name(platform_type)
    ensure(channel != "", f"unsupported channel config for platformType={platform_type}")
    channels = cfg.setdefault("channels", {})
    channel_cfg = channels.setdefault(channel, {})
    accounts = channel_cfg.setdefault("accounts", {})
    bot_id = str(bot.get("botId") or "").strip()
    existing = accounts.get(bot_id) or {}
    if channel == "telegram":
        accounts[bot_id] = {**existing, "enabled": True, "name": bot.get("botName") or bot_id, "botToken": bot.get("botToken") or existing.get("botToken") or ""}
        return
    channel_cfg.setdefault("mode", "polling")
    accounts[bot_id] = {
        **existing,
        "enabled": True,
        "name": bot.get("botName") or bot_id,
        "botToken": bot.get("botToken") or existing.get("botToken") or "",
        "apiBaseUrl": bot.get("openapiBaseUrl") or existing.get("apiBaseUrl") or "",
        "mode": existing.get("mode") or channel_cfg.get("mode") or "polling",
    }


def ensure_session(agent_id: str, bot: dict) -> tuple[str, Path]:
    sessions_dir = OPENCLAW_STATE_ROOT / "agents" / agent_id / "sessions"
    sessions_dir.mkdir(parents=True, exist_ok=True)
    store_path = sessions_dir / "sessions.json"
    store = load_json(store_path, {})
    session_key = f"agent:{agent_id}:main"
    existing = store.get(session_key) or {}
    session_id = str(existing.get("sessionId") or uuid4())
    session_file = sessions_dir / f"{session_id}.jsonl"
    if not session_file.exists():
        session_file.write_text(json.dumps({"type": "session", "version": 1, "id": session_id}, ensure_ascii=False) + "\n", encoding="utf-8")
    platform_type = str(bot.get("platformType") or "").strip().lower()
    channel = channel_name(platform_type)
    bot_id = str(bot.get("botId") or "").strip()
    provider_id = managed_provider_id(agent_id)
    model_id = managed_model_id(str(bot.get("modelName") or "").strip())
    next_entry = {
        "sessionId": session_id,
        "updatedAt": now_ms(),
        "sessionFile": str(session_file.resolve()),
        "label": bot.get("botName") or bot_id or agent_id,
        "displayName": bot.get("botName") or bot_id or agent_id,
        "modelProvider": provider_id,
        "model": model_id or "missing-model",
        "origin": {"label": "developer-standardized-activation", "provider": "developer", "from": "developer"},
        "systemSent": False,
        "abortedLastRun": False,
    }
    if channel:
        next_entry["channel"] = channel
        next_entry["lastChannel"] = channel
        next_entry["lastTo"] = bot_id
        next_entry["lastAccountId"] = bot_id
        next_entry["origin"]["to"] = bot_id
        next_entry["origin"]["accountId"] = bot_id
    store[session_key] = next_entry
    write_json(store_path, store)
    return session_key, store_path


def run_create(bot: dict) -> None:
    bot_id = str(bot["botId"]).strip()
    root = bot_root(bot_id)
    status = "updated" if root.exists() else "created"
    root.mkdir(parents=True, exist_ok=True)
    write_json(
        root / "bot.json",
        {
            "managedBy": "openclaw-bot-lifecycle",
            "openclawMode": "standardized",
            "mainAgentId": CURRENT_AGENT_ID,
            "botId": bot_id,
            "tenantId": bot.get("tenantId"),
            "userId": bot.get("userId"),
            "botName": bot.get("botName"),
            "platformType": bot.get("platformType"),
            "openapiBaseUrl": bot.get("openapiBaseUrl"),
            "botToken": bot.get("botToken"),
            "modelApiBaseUrl": bot.get("modelApiBaseUrl"),
            "modelApiKey": bot.get("modelApiKey"),
            "modelName": bot.get("modelName"),
            "updatedAt": now_rfc3339(),
        },
    )
    compact_summary("create", bot_id, status, "-", "bot shell created in local workspace")


def copy_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def run_publish(bot: dict, inputs: dict, security: dict, payload_root: Path) -> None:
    bot_id = str(bot["botId"]).strip()
    root = bot_root(bot_id)
    ensure(root.exists(), "managed bot does not exist; run create first")
    version = inputs.get("version") or {}
    files = inputs.get("files") or {}
    version_id = str(version.get("id") or "").strip()
    ensure(version_id != "", "inputs.version.id is required")

    approved_roots = [clean_abs(p, payload_root) for p in (security.get("approvedRoots") or []) if str(p).strip()]
    ensure(approved_roots, "security.approvedRoots must contain at least one staging root for publish")

    staging_dir = clean_abs(str(files.get("stagingDir") or ""), payload_root)
    soul_path = clean_abs(str(files.get("soulPath") or ""), payload_root)
    skill_paths = [clean_abs(str(p), payload_root) for p in (files.get("skillPaths") or []) if str(p).strip()]
    asset_paths = [clean_abs(str(p), payload_root) for p in (files.get("assetPaths") or []) if str(p).strip()]
    ensure(skill_paths, "files.skillPaths must contain at least one file")
    ensure_under(staging_dir, approved_roots, "files.stagingDir escapes approvedRoots")
    ensure_under(soul_path, approved_roots, "files.soulPath escapes approvedRoots")
    for entry in skill_paths:
        ensure_under(entry, approved_roots, "a skill path escapes approvedRoots")
    for entry in asset_paths:
        ensure_under(entry, approved_roots, "an asset path escapes approvedRoots")

    version_root = root / "versions" / version_id
    current_root = root / "current"
    if version_root.exists():
        shutil.rmtree(version_root)
    version_root.mkdir(parents=True, exist_ok=True)
    copy_file(soul_path, version_root / "SOUL.md")
    for entry in skill_paths:
        copy_file(entry, version_root / "skills" / entry.name)
    for entry in asset_paths:
        copy_file(entry, version_root / "assets" / entry.name)
    write_json(version_root / "manifest.json", files.get("manifest") or {})
    if current_root.exists():
        shutil.rmtree(current_root)
    shutil.copytree(version_root, current_root)
    write_json(
        root / "published-version.json",
        {
            "botId": bot_id,
            "versionId": version_id,
            "agentVersion": version.get("agentVersion"),
            "environment": version.get("environment"),
            "publishedAt": now_rfc3339(),
            "manifestFile": str((version_root / "manifest.json").resolve()),
        },
    )
    compact_summary("publish", bot_id, "published", version_id, "files copied into local managed-bots workspace")


def run_delete(bot: dict) -> None:
    bot_id = str(bot["botId"]).strip()
    root = bot_root(bot_id)
    managed_bot = load_json(root / "bot.json", {}) if root.exists() else {}
    bot_payload = {**managed_bot, **(bot or {})}
    tenant_id = str(bot_payload.get("tenantId") or "").strip()
    agent_id = agent_id_for(bot_id, tenant_id)
    changed = False
    cfg = load_json(OPENCLAW_CONFIG_PATH, {})
    ensure(isinstance(cfg, dict), "openclaw config is invalid")
    if remove_account_references(cfg, account_id=bot_id, agent_id=agent_id):
        changed = True
    if remove_agent(cfg, agent_id=agent_id):
        changed = True
    touch_meta(cfg)
    write_json(OPENCLAW_CONFIG_PATH, cfg)
    workspace_dir = OPENCLAW_STATE_ROOT / f"workspace-{agent_id}"
    if workspace_dir.exists():
        shutil.rmtree(workspace_dir)
        changed = True
    if agent_id != CURRENT_AGENT_ID:
        agent_state_dir = OPENCLAW_STATE_ROOT / "agents" / agent_id
        if agent_state_dir.exists():
            shutil.rmtree(agent_state_dir)
            changed = True
    if root.exists():
        shutil.rmtree(root)
        changed = True
    if changed:
        compact_summary("delete", bot_id, "deleted", "-", "managed bot removed from local workspace and openclaw state")
    else:
        compact_summary("delete", bot_id, "already_absent", "-", "managed bot was already absent")


def run_activate(bot: dict, inputs: dict) -> None:
    bot_id = str(bot["botId"]).strip()
    root = bot_root(bot_id)
    ensure(root.exists(), "managed bot does not exist; run create first")
    current_root = root / "current"
    bot_file = root / "bot.json"
    published_file = root / "published-version.json"
    ensure(current_root.exists(), "managed bot current workspace is missing; run publish first")
    ensure(bot_file.exists(), "bot.json is missing; run create first")
    ensure(published_file.exists(), "published-version.json is missing; run publish first")
    managed_bot = load_json(bot_file, {})
    published = load_json(published_file, {})
    bot_payload = {**managed_bot, **(bot or {})}
    platform_type = str(bot_payload.get("platformType") or "openapi").strip().lower() or "openapi"
    tenant_id = str(bot_payload.get("tenantId") or "").strip()
    agent_id = agent_id_for(bot_id, tenant_id)
    workspace_dir = ensure_workspace_copy(agent_id, current_root)
    agent_dir = ensure_agent_support_files(agent_id)
    primary_model = sync_managed_model_config(agent_dir, agent_id, bot_payload)
    cfg = load_json(OPENCLAW_CONFIG_PATH, {})
    ensure(isinstance(cfg, dict), "openclaw config is invalid")
    if supports_channel_config(platform_type):
        upsert_channel_account(cfg, platform_type=platform_type, bot=bot_payload)
        upsert_route(cfg, channel=channel_name(platform_type), account_id=bot_id, agent_id=agent_id)
    else:
        remove_channel_account_and_route(cfg, channel="zapry", account_id=bot_id)
    upsert_agent(cfg, agent_id=agent_id, name=str(bot_payload.get("botName") or bot_id).strip(), workspace_dir=workspace_dir, agent_dir=agent_dir, primary_model=primary_model)
    touch_meta(cfg)
    write_json(OPENCLAW_CONFIG_PATH, cfg)
    session_key, _store_path = ensure_session(agent_id, bot_payload)
    version = inputs.get("version") or {}
    version_id = str(version.get("id") or published.get("versionId") or "").strip() or "-"
    compact_summary("activate", bot_id, "activated", version_id, f"bot wired into local gateway as {agent_id} ({session_key})")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Execute standardized bot lifecycle payloads.")
    parser.add_argument("payload", nargs="?", help="Path to payload JSON")
    parser.add_argument("--bundle-url", dest="bundle_url", default="", help="Signed bundle URL")
    args = parser.parse_args()
    ensure(bool(args.payload) ^ bool(str(args.bundle_url).strip()), "provide exactly one of <payload.json> or --bundle-url <url>")
    return args


def download_bundle(bundle_url: str, temp_root: Path) -> Path:
    bundle_path = temp_root / "bundle.zip"
    extract_dir = temp_root / "bundle"
    with urllib.request.urlopen(bundle_url) as response, open(bundle_path, "wb") as target:
        shutil.copyfileobj(response, target)
    with zipfile.ZipFile(bundle_path, "r") as archive:
        for member in archive.infolist():
            member_path = Path(member.filename)
            ensure(not member_path.is_absolute(), "bundle contains absolute paths")
            ensure(".." not in member_path.parts, "bundle contains unsafe paths")
        archive.extractall(extract_dir)
    payload_path = extract_dir / "payload.json"
    ensure(payload_path.exists(), "bundle payload.json is missing")
    return payload_path


def execute_payload(payload_path: Path) -> dict:
    payload = load_payload(str(payload_path))
    action, bot, inputs, security = validate(payload)
    MANAGED_BOTS_ROOT.mkdir(parents=True, exist_ok=True)
    if action == "create":
        run_create(bot)
    elif action == "publish":
        run_publish(bot, inputs, security, payload_path.parent)
    elif action == "activate":
        run_activate(bot, inputs)
    else:
        run_delete(bot)
    return payload


def main() -> int:
    payload = {}
    try:
        args = parse_args()
        if str(args.bundle_url).strip():
            with tempfile.TemporaryDirectory(prefix="botctl-bundle-") as temp_dir:
                payload = execute_payload(download_bundle(str(args.bundle_url).strip(), Path(temp_dir)))
                return 0
        payload = execute_payload(clean_abs(str(args.payload)))
        return 0
    except Exception as exc:
        print(
            "\n".join(
                [
                    f"Action: {((payload.get('skill') or {}).get('action')) if 'payload' in locals() else 'unknown'}",
                    "Status: refused",
                    f"Reason: {exc}",
                ]
            )
        )
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
