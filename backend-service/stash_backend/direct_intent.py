from __future__ import annotations

import re
import shlex
from pathlib import Path
from typing import Any

from .types import TaggedCommand
from .utils import ensure_inside

FILE_REF_RE = re.compile(r"(?<![\w./~-])(?:~|/)?(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,12}")
SEARCH_QUOTED_RE = re.compile(r'"([^"]+)"')
READABLE_SUFFIXES = {
    ".txt",
    ".md",
    ".markdown",
    ".csv",
    ".tsv",
    ".json",
    ".yaml",
    ".yml",
    ".xml",
    ".log",
    ".pdf",
}
WRITABLE_SUFFIXES = {".txt", ".md", ".csv"}
SUMMARY_WORDS = ("summarize", "summary", "summarise")
READ_WORDS = ("read", "open", "show", "tell me", "what is in", "what's in")
LIST_WORDS = ("list files", "show files", "folder structure", "tree", "what files")
SEARCH_WORDS = ("find", "search", "grep", "look for")
WRITE_WORDS = ("create", "write", "save", "export", "make")


def _normalize_path(raw: str, project_root: Path) -> Path | None:
    token = raw.strip().strip("`'\"")
    if not token or "://" in token:
        return None
    path = Path(token).expanduser()
    candidate = path.resolve() if path.is_absolute() else (project_root / path).resolve()
    if not ensure_inside(project_root.resolve(), candidate):
        return None
    return candidate


def _extract_paths(user_message: str, parts: list[dict[str, Any]] | None, project_root: Path) -> list[Path]:
    found: list[Path] = []
    seen: set[str] = set()
    for match in FILE_REF_RE.findall(user_message):
        candidate = _normalize_path(match, project_root)
        if candidate is None:
            continue
        key = str(candidate).lower()
        if key in seen:
            continue
        seen.add(key)
        found.append(candidate)
    for part in parts or []:
        if not isinstance(part, dict):
            continue
        path = str(part.get("path") or "").strip()
        if not path:
            continue
        candidate = _normalize_path(path, project_root)
        if candidate is None:
            continue
        key = str(candidate).lower()
        if key in seen:
            continue
        seen.add(key)
        found.append(candidate)
    return found


def _pick_output_path(user_message: str, source: Path | None, project_root: Path) -> Path | None:
    for raw in FILE_REF_RE.findall(user_message):
        candidate = _normalize_path(raw, project_root)
        if candidate is None:
            continue
        if source is not None and candidate.resolve() == source.resolve():
            continue
        if candidate.suffix.lower() in WRITABLE_SUFFIXES:
            return candidate
    if source is None:
        return None
    stem = source.stem or "output"
    return (project_root / f"{stem}_summary.txt").resolve()


def _to_rel(project_root: Path, path: Path) -> str:
    try:
        return str(path.resolve().relative_to(project_root.resolve()))
    except ValueError:
        return str(path.resolve())


def _cmd(command: str, cwd: Path) -> TaggedCommand:
    return TaggedCommand(raw=command, cmd=command, worktree="main", cwd=str(cwd))


def _build_pdf_extract_script(source: Path, output: Path | None = None) -> str:
    source_q = repr(str(source))
    if output is None:
        return (
            "python3 -c "
            + shlex.quote(
                "from pypdf import PdfReader; "
                f"r=PdfReader({source_q}); "
                "t='\\n\\n'.join(((p.extract_text() or '').strip()) for p in r.pages); "
                "print(t[:120000])"
            )
        )
    output_q = repr(str(output))
    return (
        "python3 -c "
        + shlex.quote(
            "from pypdf import PdfReader; "
            f"r=PdfReader({source_q}); "
            "t='\\n\\n'.join(((p.extract_text() or '').strip()) for p in r.pages); "
            "summary='\\n'.join(t.splitlines()[:80]); "
            f"open({output_q}, 'w', encoding='utf-8').write(summary); "
            f"print('created: {str(output)}')"
        )
    )


def _build_text_summary_script(source: Path, output: Path | None = None) -> str:
    source_q = repr(str(source))
    if output is None:
        return (
            "python3 -c "
            + shlex.quote(
                "from pathlib import Path; "
                f"p=Path({source_q}); "
                "text=p.read_text(encoding='utf-8', errors='replace'); "
                "lines=[ln.strip() for ln in text.splitlines() if ln.strip()][:80]; "
                "print('\\n'.join(lines))"
            )
        )
    output_q = repr(str(output))
    return (
        "python3 -c "
        + shlex.quote(
            "from pathlib import Path; "
            f"src=Path({source_q}); dst=Path({output_q}); "
            "text=src.read_text(encoding='utf-8', errors='replace'); "
            "lines=[ln.strip() for ln in text.splitlines() if ln.strip()]; "
            "summary='\\n'.join(lines[:100]); "
            "dst.write_text(summary, encoding='utf-8'); "
            f"print('created: {str(output)}')"
        )
    )


def _build_csv_summary_script(source: Path, output: Path | None = None) -> str:
    source_q = repr(str(source))
    if output is None:
        return (
            "python3 -c "
            + shlex.quote(
                "import csv; from pathlib import Path; "
                f"p=Path({source_q}); "
                "rows=list(csv.reader(p.open('r', encoding='utf-8', errors='replace'))); "
                "head=rows[0] if rows else []; "
                "print(f'rows={max(len(rows)-1,0)} cols={len(head)} headers={head}')"
            )
        )
    output_q = repr(str(output))
    return (
        "python3 -c "
        + shlex.quote(
            "import csv; from pathlib import Path; "
            f"src=Path({source_q}); dst=Path({output_q}); "
            "rows=list(csv.reader(src.open('r', encoding='utf-8', errors='replace'))); "
            "head=rows[0] if rows else []; "
            "preview='\\n'.join([', '.join(head)] + [', '.join(r) for r in rows[1:11]]); "
            "dst.write_text(preview, encoding='utf-8'); "
            f"print('created: {str(output)}')"
        )
    )


def _build_find_command(user_message: str) -> str:
    quoted = SEARCH_QUOTED_RE.findall(user_message)
    if quoted:
        needle = shlex.quote(quoted[0])
        return f"grep -R -n -- {needle} ."
    suffixes = [token for token in FILE_REF_RE.findall(user_message) if token.startswith(".")]
    if suffixes:
        ext = suffixes[0]
        return f"find . -type f -name '*{ext}'"
    return "find . -type f | sed -n '1,220p'"


def build_direct_commands(
    *,
    user_message: str,
    parts: list[dict[str, Any]] | None,
    project_root: Path,
) -> list[TaggedCommand]:
    msg = user_message.strip()
    lowered = msg.lower()
    paths = _extract_paths(msg, parts, project_root)
    source = paths[0] if paths else None
    wants_summary = any(token in lowered for token in SUMMARY_WORDS)
    wants_read = wants_summary or any(token in lowered for token in READ_WORDS)
    wants_list = any(token in lowered for token in LIST_WORDS)
    wants_search = any(token in lowered for token in SEARCH_WORDS)
    wants_write = any(token in lowered for token in WRITE_WORDS)
    wants_output_file = wants_write and any(ext in lowered for ext in WRITABLE_SUFFIXES)

    commands: list[TaggedCommand] = []
    cwd = project_root.resolve()

    if wants_search:
        commands.append(_cmd(_build_find_command(msg), cwd))
        return commands

    if wants_list and source is None:
        commands.append(_cmd("find . -maxdepth 4 -mindepth 1 | sed -n '1,220p'", cwd))
        return commands

    if source is None:
        if wants_list or wants_search:
            commands.append(_cmd("find . -maxdepth 4 -mindepth 1 | sed -n '1,220p'", cwd))
            return commands
        return []

    source_suffix = source.suffix.lower()
    source_rel = _to_rel(cwd, source)
    source_rel_q = shlex.quote(source_rel)

    output_target: Path | None = None
    if wants_output_file:
        output_target = _pick_output_path(msg, source, cwd)

    if wants_read or wants_write:
        if source_suffix == ".pdf":
            if output_target is not None:
                out_rel = _to_rel(cwd, output_target)
                commands.append(_cmd(_build_pdf_extract_script(source, cwd / out_rel), cwd))
            else:
                commands.append(_cmd(_build_pdf_extract_script(source), cwd))
            return commands

        if source_suffix in {".csv", ".tsv"}:
            if output_target is not None:
                out_rel = _to_rel(cwd, output_target)
                commands.append(_cmd(_build_csv_summary_script(source, cwd / out_rel), cwd))
            elif wants_summary:
                commands.append(_cmd(_build_csv_summary_script(source), cwd))
            else:
                commands.append(_cmd(f"sed -n '1,220p' {source_rel_q}", cwd))
            return commands

        if source_suffix in READABLE_SUFFIXES:
            if output_target is not None:
                out_rel = _to_rel(cwd, output_target)
                commands.append(_cmd(_build_text_summary_script(source, cwd / out_rel), cwd))
            elif wants_summary:
                commands.append(_cmd(_build_text_summary_script(source), cwd))
            else:
                commands.append(_cmd(f"sed -n '1,220p' {source_rel_q}", cwd))
            return commands

    return []
