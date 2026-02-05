from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from .runtime_config import RuntimeConfig

FALLBACK_BIN_DIRS = (
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
    "/bin",
    "~/.local/bin",
)


def resolve_binary(binary: str) -> str | None:
    candidate = Path(binary).expanduser()
    if "/" in binary or binary.startswith("."):
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate.resolve())
        return None

    found = shutil.which(binary)
    if found:
        return found

    for raw_dir in FALLBACK_BIN_DIRS:
        base = Path(raw_dir).expanduser()
        path = (base / binary).expanduser()
        if path.exists() and os.access(path, os.X_OK):
            return str(path.resolve())
    return None


def is_codex_model_config_error(output: str) -> bool:
    lowered = output.lower()
    checks = (
        "reasoning.effort",
        "unsupported value",
        "not supported when using codex with a chatgpt account",
        "unsupported model",
        "unknown model",
        "invalid model",
    )
    return any(token in lowered for token in checks)


def codex_integration_status(runtime: RuntimeConfig) -> dict[str, Any]:
    resolved = resolve_binary(runtime.codex_bin)
    uv_resolved = resolve_binary("uv")
    openai_api_key_set = bool(runtime.openai_api_key)
    status: dict[str, Any] = {
        "planner_backend": runtime.planner_backend,
        "codex_mode": runtime.codex_mode,
        "execution_mode": runtime.execution_mode,
        "codex_bin": runtime.codex_bin,
        "codex_bin_resolved": resolved,
        "codex_available": resolved is not None,
        "planner_mode": runtime.planner_mode,
        "execution_parallel_reads_enabled": runtime.execution_parallel_reads_enabled,
        "execution_parallel_reads_max_workers": runtime.execution_parallel_reads_max_workers,
        "uv_bin_resolved": uv_resolved,
        "uv_available": uv_resolved is not None,
        "planner_cmd_configured": bool(runtime.planner_cmd),
        "codex_planner_model": runtime.codex_planner_model or "",
        "openai_api_key_set": openai_api_key_set,
        "openai_planner_configured": openai_api_key_set and bool(runtime.openai_model),
        "openai_model": runtime.openai_model,
        "openai_base_url": runtime.openai_base_url,
    }

    if runtime.codex_mode != "cli":
        status["login_checked"] = False
        status["login_ok"] = None
        status["detail"] = "CLI login check skipped because codex_mode is not 'cli'."
    elif not resolved:
        status["login_checked"] = False
        status["login_ok"] = False
        status["detail"] = "Codex binary is not executable."
    else:
        try:
            proc = subprocess.run(
                [resolved, "login", "status"],
                capture_output=True,
                text=True,
                timeout=10,
                check=False,
            )
            raw = ((proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")).strip()
            status["login_checked"] = True
            status["login_ok"] = proc.returncode == 0
            status["detail"] = (raw[:1000] if raw else "Codex login check executed.")
            status["login_exit_code"] = int(proc.returncode)
        except Exception as exc:
            status["login_checked"] = True
            status["login_ok"] = False
            status["detail"] = f"Failed to run `codex login status`: {exc}"

    codex_ready = bool(status.get("codex_available")) and bool(status.get("login_ok"))
    openai_ready = bool(status.get("openai_planner_configured"))
    status["codex_planner_ready"] = codex_ready
    status["openai_planner_ready"] = openai_ready
    status["gpt_via_codex_cli_possible"] = codex_ready

    required_blockers: list[str] = []
    recommendations: list[str] = []
    needs_openai_key = False
    if runtime.planner_backend == "openai_api":
        if not openai_ready:
            required_blockers.append("OpenAI API key is required because OpenAI planner mode is selected.")
            needs_openai_key = True
    elif runtime.planner_backend == "codex_cli":
        if not codex_ready:
            required_blockers.append("Codex CLI is not ready. Verify Codex is installed and run `codex login`.")
    else:
        if not codex_ready and not openai_ready:
            required_blockers.append("No AI planner is ready. Sign in to Codex CLI or add an OpenAI API key.")
            needs_openai_key = True

    if uv_resolved is None:
        recommendations.append("Missing `uv` CLI in backend runtime PATH. Re-run installer (`./scripts/install_stack.sh`) to provision runtime tools.")

    status["planner_ready"] = not required_blockers
    status["required_blockers"] = required_blockers
    status["recommendations"] = recommendations
    status["needs_openai_key"] = needs_openai_key
    status["blockers"] = required_blockers
    return status
