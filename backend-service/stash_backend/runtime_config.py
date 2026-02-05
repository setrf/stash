from __future__ import annotations

import json
import logging
import os
import threading
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

from .config import Settings

logger = logging.getLogger(__name__)

PLANNER_BACKENDS = {"auto", "codex_cli", "openai_api"}
CODEX_MODES = {"cli", "shell"}
PLANNER_MODES = {"fast", "balanced", "quality"}
EXECUTION_MODES = {"planner", "execute"}


@dataclass(slots=True)
class RuntimeConfig:
    planner_backend: str = "auto"
    codex_mode: str = "cli"
    codex_bin: str = "codex"
    codex_planner_model: str | None = None
    planner_cmd: str | None = None
    planner_timeout_seconds: int = 60
    planner_mode: str = "fast"
    execution_mode: str = "execute"
    execution_parallel_reads_enabled: bool = True
    execution_parallel_reads_max_workers: int = 3
    openai_api_key: str | None = None
    openai_model: str = "gpt-5"
    openai_base_url: str = "https://api.openai.com/v1"
    openai_timeout_seconds: int = 60

    @classmethod
    def from_settings(cls, settings: Settings) -> RuntimeConfig:
        return cls(
            planner_backend="auto",
            codex_mode=settings.codex_mode or "cli",
            codex_bin=settings.codex_bin or "codex",
            codex_planner_model=settings.codex_planner_model or None,
            planner_cmd=settings.planner_cmd,
            planner_timeout_seconds=settings.planner_timeout_seconds,
            planner_mode=settings.planner_mode if settings.planner_mode in PLANNER_MODES else "fast",
            execution_mode=settings.execution_mode if settings.execution_mode in EXECUTION_MODES else "execute",
            execution_parallel_reads_enabled=bool(settings.execution_parallel_reads_enabled),
            execution_parallel_reads_max_workers=max(1, min(settings.execution_parallel_reads_max_workers, 8)),
            openai_api_key=settings.openai_api_key,
            openai_model=settings.openai_model or "gpt-5",
            openai_base_url=settings.openai_base_url or "https://api.openai.com/v1",
            openai_timeout_seconds=settings.openai_timeout_seconds,
        )


def _default_runtime_config_path() -> Path:
    return Path.home() / "Library" / "Application Support" / "StashLocal" / "runtime-config.json"


class RuntimeConfigStore:
    def __init__(self, settings: Settings):
        self._lock = threading.RLock()
        self._path = Path(settings.runtime_config_path).expanduser() if settings.runtime_config_path else _default_runtime_config_path()
        self._config = RuntimeConfig.from_settings(settings)
        self._load_from_disk()

    @property
    def path(self) -> Path:
        return self._path

    def get(self) -> RuntimeConfig:
        with self._lock:
            return RuntimeConfig(**asdict(self._config))

    def public_view(self) -> dict[str, Any]:
        cfg = self.get()
        return {
            "planner_backend": cfg.planner_backend,
            "codex_mode": cfg.codex_mode,
            "codex_bin": cfg.codex_bin,
            "codex_planner_model": cfg.codex_planner_model or "",
            "planner_cmd": cfg.planner_cmd,
            "planner_timeout_seconds": cfg.planner_timeout_seconds,
            "planner_mode": cfg.planner_mode,
            "execution_mode": cfg.execution_mode,
            "execution_parallel_reads_enabled": cfg.execution_parallel_reads_enabled,
            "execution_parallel_reads_max_workers": cfg.execution_parallel_reads_max_workers,
            "openai_api_key_set": bool(cfg.openai_api_key),
            "openai_model": cfg.openai_model,
            "openai_base_url": cfg.openai_base_url,
            "openai_timeout_seconds": cfg.openai_timeout_seconds,
            "config_path": str(self._path),
        }

    def update(
        self,
        *,
        planner_backend: str | None = None,
        codex_mode: str | None = None,
        codex_bin: str | None = None,
        codex_planner_model: str | None = None,
        planner_cmd: str | None = None,
        clear_planner_cmd: bool = False,
        planner_timeout_seconds: int | None = None,
        planner_mode: str | None = None,
        execution_mode: str | None = None,
        execution_parallel_reads_enabled: bool | None = None,
        execution_parallel_reads_max_workers: int | None = None,
        openai_api_key: str | None = None,
        clear_openai_api_key: bool = False,
        openai_model: str | None = None,
        openai_base_url: str | None = None,
        openai_timeout_seconds: int | None = None,
    ) -> RuntimeConfig:
        with self._lock:
            next_cfg = RuntimeConfig(**asdict(self._config))

            if planner_backend is not None:
                pb = planner_backend.strip().lower()
                if pb not in PLANNER_BACKENDS:
                    raise ValueError("Invalid planner_backend")
                next_cfg.planner_backend = pb

            if codex_mode is not None:
                mode = codex_mode.strip().lower()
                if mode not in CODEX_MODES:
                    raise ValueError("Invalid codex_mode")
                next_cfg.codex_mode = mode

            if codex_bin is not None:
                cleaned = codex_bin.strip()
                if not cleaned:
                    raise ValueError("codex_bin cannot be empty")
                next_cfg.codex_bin = cleaned

            if codex_planner_model is not None:
                cleaned = codex_planner_model.strip()
                next_cfg.codex_planner_model = cleaned or None

            if clear_planner_cmd:
                next_cfg.planner_cmd = None
            elif planner_cmd is not None:
                cleaned = planner_cmd.strip()
                next_cfg.planner_cmd = cleaned or None

            if planner_timeout_seconds is not None:
                if planner_timeout_seconds < 20 or planner_timeout_seconds > 600:
                    raise ValueError("planner_timeout_seconds must be between 20 and 600")
                next_cfg.planner_timeout_seconds = planner_timeout_seconds

            if planner_mode is not None:
                cleaned_mode = planner_mode.strip().lower()
                if cleaned_mode not in PLANNER_MODES:
                    raise ValueError("planner_mode must be one of: fast, balanced, quality")
                next_cfg.planner_mode = cleaned_mode

            if execution_mode is not None:
                cleaned_mode = execution_mode.strip().lower()
                if cleaned_mode not in EXECUTION_MODES:
                    raise ValueError("execution_mode must be one of: planner, execute")
                next_cfg.execution_mode = cleaned_mode

            if execution_parallel_reads_enabled is not None:
                next_cfg.execution_parallel_reads_enabled = bool(execution_parallel_reads_enabled)

            if execution_parallel_reads_max_workers is not None:
                if execution_parallel_reads_max_workers < 1 or execution_parallel_reads_max_workers > 8:
                    raise ValueError("execution_parallel_reads_max_workers must be between 1 and 8")
                next_cfg.execution_parallel_reads_max_workers = execution_parallel_reads_max_workers

            if clear_openai_api_key:
                next_cfg.openai_api_key = None
            elif openai_api_key is not None:
                cleaned = openai_api_key.strip()
                next_cfg.openai_api_key = cleaned or None

            if openai_model is not None:
                cleaned = openai_model.strip()
                if not cleaned:
                    raise ValueError("openai_model cannot be empty")
                next_cfg.openai_model = cleaned

            if openai_base_url is not None:
                cleaned = openai_base_url.strip()
                if not cleaned:
                    raise ValueError("openai_base_url cannot be empty")
                next_cfg.openai_base_url = cleaned

            if openai_timeout_seconds is not None:
                if openai_timeout_seconds < 5 or openai_timeout_seconds > 300:
                    raise ValueError("openai_timeout_seconds must be between 5 and 300")
                next_cfg.openai_timeout_seconds = openai_timeout_seconds

            self._config = next_cfg
            self._persist_locked()
            return RuntimeConfig(**asdict(self._config))

    def _load_from_disk(self) -> None:
        if not self._path.exists():
            return
        try:
            raw = self._path.read_text(encoding="utf-8")
            parsed = json.loads(raw)
            if not isinstance(parsed, dict):
                return
        except Exception:
            logger.exception("Failed loading runtime config from %s", self._path)
            return

        try:
            self.update(
                planner_backend=parsed.get("planner_backend"),
                codex_mode=parsed.get("codex_mode"),
                codex_bin=parsed.get("codex_bin"),
                codex_planner_model=parsed.get("codex_planner_model"),
                planner_cmd=parsed.get("planner_cmd"),
                planner_timeout_seconds=parsed.get("planner_timeout_seconds"),
                planner_mode=parsed.get("planner_mode"),
                execution_mode=parsed.get("execution_mode"),
                execution_parallel_reads_enabled=parsed.get("execution_parallel_reads_enabled"),
                execution_parallel_reads_max_workers=parsed.get("execution_parallel_reads_max_workers"),
                openai_api_key=parsed.get("openai_api_key"),
                openai_model=parsed.get("openai_model"),
                openai_base_url=parsed.get("openai_base_url"),
                openai_timeout_seconds=parsed.get("openai_timeout_seconds"),
            )
        except Exception:
            logger.exception("Runtime config file is invalid; keeping defaults")

    def _persist_locked(self) -> None:
        self._path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(asdict(self._config), indent=2, ensure_ascii=True)
        temp_path = self._path.with_suffix(".tmp")
        temp_path.write_text(payload + "\n", encoding="utf-8")
        os.replace(temp_path, self._path)
        try:
            os.chmod(self._path, 0o600)
        except OSError:
            pass
