from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from .runtime_config import RuntimeConfig


def resolve_binary(binary: str) -> str | None:
    candidate = Path(binary).expanduser()
    if "/" in binary or binary.startswith("."):
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate.resolve())
        return None
    return shutil.which(binary)


def codex_integration_status(runtime: RuntimeConfig) -> dict[str, Any]:
    resolved = resolve_binary(runtime.codex_bin)
    openai_api_key_set = bool(runtime.openai_api_key)
    status: dict[str, Any] = {
        "planner_backend": runtime.planner_backend,
        "codex_mode": runtime.codex_mode,
        "codex_bin": runtime.codex_bin,
        "codex_bin_resolved": resolved,
        "codex_available": resolved is not None,
        "planner_cmd_configured": bool(runtime.planner_cmd),
        "codex_planner_model": runtime.codex_planner_model,
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
            status["login_ok"] = proc.returncode == 0 and bool(raw)
            status["detail"] = raw[:1000]
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
    if runtime.planner_backend == "openai_api":
        if not openai_ready:
            required_blockers.append("OpenAI API key is missing for OpenAI planner mode.")
        if not codex_ready:
            recommendations.append("Configure Codex CLI login to enable GPT-through-Codex flow.")
    elif runtime.planner_backend == "codex_cli":
        if not codex_ready:
            required_blockers.append("Codex CLI is not ready. Verify binary path and login status.")
        if not openai_ready:
            recommendations.append("Configure OpenAI API key for planner fallback.")
    else:
        if not codex_ready and not openai_ready:
            required_blockers.append("Neither Codex CLI nor OpenAI API planner is ready.")
        elif not codex_ready:
            recommendations.append("Codex CLI is not ready; currently relying on OpenAI API planner only.")
        if not openai_ready:
            recommendations.append("Configure OpenAI API key for planner fallback.")

    status["planner_ready"] = not required_blockers
    status["required_blockers"] = required_blockers
    status["recommendations"] = recommendations
    status["blockers"] = required_blockers
    return status
