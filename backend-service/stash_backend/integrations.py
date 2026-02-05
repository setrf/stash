from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path
from typing import Any

from .config import Settings


def resolve_binary(binary: str) -> str | None:
    candidate = Path(binary).expanduser()
    if "/" in binary or binary.startswith("."):
        if candidate.exists() and os.access(candidate, os.X_OK):
            return str(candidate.resolve())
        return None
    return shutil.which(binary)


def codex_integration_status(settings: Settings) -> dict[str, Any]:
    resolved = resolve_binary(settings.codex_bin)
    openai_enabled = bool(settings.openai_api_key and settings.openai_model)
    status: dict[str, Any] = {
        "codex_mode": settings.codex_mode,
        "codex_bin": settings.codex_bin,
        "codex_bin_resolved": resolved,
        "codex_available": resolved is not None,
        "planner_cmd_configured": bool(settings.planner_cmd),
        "openai_planner_configured": openai_enabled,
        "openai_model": settings.openai_model if openai_enabled else None,
        "openai_base_url": settings.openai_base_url if openai_enabled else None,
    }

    if settings.codex_mode != "cli":
        status["login_checked"] = False
        status["login_ok"] = None
        status["detail"] = "CLI login check skipped because STASH_CODEX_MODE is not 'cli'."
        return status

    if not resolved:
        status["login_checked"] = False
        status["login_ok"] = False
        status["detail"] = "Codex binary is not executable."
        return status

    try:
        proc = subprocess.run(
            [resolved, "login", "status"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except Exception as exc:
        status["login_checked"] = True
        status["login_ok"] = False
        status["detail"] = f"Failed to run `codex login status`: {exc}"
        return status

    raw = ((proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")).strip()
    status["login_checked"] = True
    status["login_ok"] = proc.returncode == 0 and bool(raw)
    status["detail"] = raw[:1000]
    status["login_exit_code"] = int(proc.returncode)
    return status
