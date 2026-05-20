#!/usr/bin/env bash
set -euo pipefail

ASSET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$ASSET_DIR/patches/deepseek-v4-thinking-compat.patch"

HERMES_HOME="${HERMES_HOME:-$HOME/.hermes}"
HERMES_REPO="${HERMES_REPO:-$HERMES_HOME/hermes-agent}"
CONFIG_FILE="${CONFIG_FILE:-$HERMES_HOME/config.yaml}"
PYTHON_BIN="${PYTHON_BIN:-$HERMES_REPO/venv/bin/python}"

CHECK_ONLY=0
SKIP_TESTS=0
NO_RESTART=0
SKIP_SMOKE=0

log() {
  printf '[hermes-deepseek-compat] %s\n' "$*"
}

die() {
  printf '[hermes-deepseek-compat] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: apply-hermes-deepseek-compat.sh [options]

Options:
  --check-only   Only check whether patch and settings are already correct.
  --skip-tests   Skip targeted pytest checks.
  --no-restart   Do not restart hermes-gateway.
  --skip-smoke   Skip CLI smoke test.
  -h, --help     Show this help.

Environment:
  HERMES_HOME    Defaults to $HOME/.hermes
  HERMES_REPO    Defaults to $HERMES_HOME/hermes-agent
  CONFIG_FILE    Defaults to $HERMES_HOME/config.yaml
  PYTHON_BIN     Defaults to $HERMES_REPO/venv/bin/python
USAGE
}

while (($#)); do
  case "$1" in
    --check-only)
      CHECK_ONLY=1
      ;;
    --skip-tests)
      SKIP_TESTS=1
      ;;
    --no-restart)
      NO_RESTART=1
      ;;
    --skip-smoke)
      SKIP_SMOKE=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
  shift
done

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_file() {
  [[ -f "$1" ]] || die "missing file: $1"
}

require_dir() {
  [[ -d "$1" ]] || die "missing directory: $1"
}

ensure_preflight() {
  require_cmd git
  require_file "$PATCH_FILE"
  require_dir "$HERMES_REPO"
  require_file "$PYTHON_BIN"
}

ensure_code_patch() {
  log "checking Hermes code patch"
  (
    cd "$HERMES_REPO"
    if git apply --reverse --check "$PATCH_FILE" >/dev/null 2>&1; then
      log "code patch already applied"
      exit 0
    fi

    if git apply --check "$PATCH_FILE" >/dev/null 2>&1; then
      if (( CHECK_ONLY )); then
        die "code patch is not applied"
      fi
      git apply "$PATCH_FILE"
      log "code patch applied"
      exit 0
    fi

    die "patch does not apply cleanly; Hermes upstream likely changed and this patch needs refresh"
  )
}

ensure_config() {
  log "checking Hermes config"
  "$PYTHON_BIN" - "$CONFIG_FILE" "$CHECK_ONLY" <<'PY'
from __future__ import annotations

import datetime as _dt
import shutil
import sys
from pathlib import Path

try:
    import yaml
except Exception as exc:  # pragma: no cover - runtime guard
    raise SystemExit(f"PyYAML is required to update config.yaml: {exc}")

config_path = Path(sys.argv[1])
check_only = sys.argv[2] == "1"
original = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
data = yaml.safe_load(original) if original.strip() else {}
if not isinstance(data, dict):
    raise SystemExit("config root must be a YAML mapping")

state = {"changed": False}


def ensure_dict(parent: dict, key: str) -> dict:
    value = parent.get(key)
    if not isinstance(value, dict):
        value = {}
        parent[key] = value
        state["changed"] = True
    return value


def set_path(path: tuple[str, ...], value) -> None:
    cur = data
    for key in path[:-1]:
        cur = ensure_dict(cur, key)
    leaf = path[-1]
    if cur.get(leaf) != value:
        cur[leaf] = value
        state["changed"] = True


settings = [
    (("model", "default"), "deepseek-v4-pro"),
    (("model", "provider"), "deepseek"),
    (("model", "base_url"), "https://api.deepseek.com/v1"),
    (("model", "api_mode"), "chat_completions"),
    (("agent", "reasoning_effort"), "none"),
]

for path, value in settings:
    set_path(path, value)

agent = ensure_dict(data, "agent")
tool_use_enforcement = agent.get("tool_use_enforcement")
if not isinstance(tool_use_enforcement, list):
    tool_use_enforcement = []
    agent["tool_use_enforcement"] = tool_use_enforcement
    state["changed"] = True
if "deepseek" not in tool_use_enforcement:
    tool_use_enforcement.append("deepseek")
    state["changed"] = True

if check_only:
    if state["changed"]:
        raise SystemExit("config.yaml needs updates")
    print("config.yaml already matches desired settings")
    raise SystemExit(0)

if not state["changed"]:
    print("config.yaml already matches desired settings")
    raise SystemExit(0)

stamp = _dt.datetime.now().strftime("%Y%m%d-%H%M%S")
backup_path = config_path.with_name(f"{config_path.name}.backup-{stamp}-hermes-deepseek-compat")
if config_path.exists():
    shutil.copy2(config_path, backup_path)
updated = yaml.safe_dump(data, allow_unicode=True, sort_keys=False, default_flow_style=False)
config_path.write_text(updated, encoding="utf-8")
if backup_path.exists():
    print(f"config.yaml updated; backup: {backup_path}")
else:
    print("config.yaml created")
PY
}

run_config_check() {
  if (( CHECK_ONLY )); then
    log "check-only mode: skipping Hermes config validation command"
    return
  fi

  log "running Hermes config check"
  (
    cd "$HERMES_REPO"
    HERMES_HOME="$HERMES_HOME" "$PYTHON_BIN" -m hermes_cli.main config check
  )
}

run_tests() {
  if (( SKIP_TESTS )); then
    log "--skip-tests set: skipping pytest checks"
    return
  fi

  log "running targeted pytest checks"
  (
    cd "$HERMES_REPO"
    "$PYTHON_BIN" -m pytest tests/agent/transports/test_chat_completions.py -k "deepseek or kimi_thinking or kimi_reasoning_effort"
    "$PYTHON_BIN" -m pytest tests/run_agent/test_deepseek_reasoning_content_echo.py
  )
}

restart_gateway() {
  if (( NO_RESTART )); then
    log "--no-restart set: skipping hermes-gateway restart"
    return
  fi

  if ! command -v systemctl >/dev/null 2>&1; then
    log "systemctl not found: skipping hermes-gateway restart"
    return
  fi

  if ! systemctl status hermes-gateway.service >/dev/null 2>&1 && \
     ! systemctl list-unit-files hermes-gateway.service >/dev/null 2>&1; then
    log "hermes-gateway.service not found: skipping restart"
    return
  fi

  if (( CHECK_ONLY )); then
    log "check-only mode: skipping hermes-gateway restart"
    return
  fi

  log "restarting hermes-gateway"
  sudo systemctl restart hermes-gateway.service
  systemctl is-active --quiet hermes-gateway.service
  log "hermes-gateway is active"
}

run_smoke() {
  if (( SKIP_SMOKE )); then
    log "--skip-smoke set: skipping CLI smoke"
    return
  fi

  if (( CHECK_ONLY )); then
    log "check-only mode: skipping CLI smoke"
    return
  fi

  require_cmd timeout
  log "running CLI smoke"
  local output
  if ! output="$(HERMES_HOME="$HERMES_HOME" timeout 180 "$PYTHON_BIN" -m hermes_cli.main -z "请使用 terminal 工具执行 printf ds_content_ok，然后只回复输出。" 2>&1)"; then
    printf '%s\n' "$output"
    die "CLI smoke failed"
  fi
  printf '%s\n' "$output" | grep -q "ds_content_ok" || {
    printf '%s\n' "$output"
    die "CLI smoke did not contain ds_content_ok"
  }
  log "CLI smoke passed"
}

main() {
  log "asset dir: $ASSET_DIR"
  log "Hermes home: $HERMES_HOME"
  log "Hermes repo: $HERMES_REPO"
  ensure_preflight
  ensure_code_patch
  ensure_config
  run_config_check
  run_tests
  restart_gateway
  run_smoke
  log "done"
}

main "$@"
