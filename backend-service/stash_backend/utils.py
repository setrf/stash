from __future__ import annotations

import hashlib
import json
import re
import uuid
from datetime import datetime, timezone
from pathlib import Path


ID_RE = re.compile(r"[^a-zA-Z0-9_-]+")


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def make_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex[:12]}"


def stable_slug(value: str, *, max_len: int = 48) -> str:
    cleaned = ID_RE.sub("-", value.strip()).strip("-").lower() or "default"
    digest = hashlib.sha1(value.encode("utf-8")).hexdigest()[:8]
    if len(cleaned) > max_len:
        cleaned = cleaned[:max_len]
    return f"{cleaned}-{digest}"


def ensure_inside(base: Path, target: Path) -> bool:
    try:
        target.resolve().relative_to(base.resolve())
        return True
    except ValueError:
        return False


def dumps_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=True)


def loads_json(value: str | None, default: object) -> object:
    if not value:
        return default
    try:
        return json.loads(value)
    except json.JSONDecodeError:
        return default
