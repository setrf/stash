from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    host: str = "127.0.0.1"
    port: int = 8765
    scan_interval_seconds: int = 5
    vector_dim: int = 256
    max_file_size_bytes: int = 5 * 1024 * 1024
    chunk_size_chars: int = 1200
    chunk_overlap_chars: int = 200
    codex_mode: str = "cli"
    codex_bin: str = "codex"
    planner_cmd: str | None = None
    planner_timeout_seconds: int = 150
    openai_api_key: str | None = None
    openai_model: str = "gpt-5-mini"
    openai_base_url: str = "https://api.openai.com/v1"
    openai_timeout_seconds: int = 60
    log_level: str = "INFO"
    enable_hidden_files: bool = False


def load_settings() -> Settings:
    openai_api_key = (os.getenv("STASH_OPENAI_API_KEY") or os.getenv("OPENAI_API_KEY") or "").strip()
    return Settings(
        host=os.getenv("STASH_HOST", "127.0.0.1"),
        port=int(os.getenv("STASH_PORT", "8765")),
        scan_interval_seconds=int(os.getenv("STASH_SCAN_INTERVAL_SECONDS", "5")),
        vector_dim=int(os.getenv("STASH_VECTOR_DIM", "256")),
        max_file_size_bytes=int(os.getenv("STASH_MAX_FILE_SIZE_BYTES", str(5 * 1024 * 1024))),
        chunk_size_chars=int(os.getenv("STASH_CHUNK_SIZE_CHARS", "1200")),
        chunk_overlap_chars=int(os.getenv("STASH_CHUNK_OVERLAP_CHARS", "200")),
        codex_mode=os.getenv("STASH_CODEX_MODE", "cli").strip().lower(),
        codex_bin=os.getenv("STASH_CODEX_BIN", "codex").strip(),
        planner_cmd=os.getenv("STASH_PLANNER_CMD"),
        planner_timeout_seconds=int(os.getenv("STASH_PLANNER_TIMEOUT_SECONDS", "150")),
        openai_api_key=openai_api_key or None,
        openai_model=os.getenv("STASH_OPENAI_MODEL", "gpt-5-mini").strip(),
        openai_base_url=os.getenv("STASH_OPENAI_BASE_URL", "https://api.openai.com/v1").strip(),
        openai_timeout_seconds=int(os.getenv("STASH_OPENAI_TIMEOUT_SECONDS", "60")),
        log_level=os.getenv("STASH_LOG_LEVEL", "INFO").strip().upper(),
        enable_hidden_files=os.getenv("STASH_ENABLE_HIDDEN_FILES", "false").strip().lower() == "true",
    )
