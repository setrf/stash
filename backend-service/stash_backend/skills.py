from __future__ import annotations

from pathlib import Path

INDEXING_SKILL = """# Indexing Skill

Goal: keep project context fresh and searchable.

Rules:
- Index new and changed text-like files in the project root.
- Keep chunks concise and preserve path/source references.
- Do not index `.stash/` internals.
- Emit progress events for start/progress/completion.
"""

EXECUTION_SKILL = """# File and Terminal Execution Skill

Goal: execute validated project operations safely.

Rules:
- Accept only tagged commands from planner/orchestrator.
- Execute from controlled worktree folders under `.stash/worktrees/` unless explicit safe cwd is provided.
- Never auto-run `sudo`.
- Return stdout/stderr and exit code for every step.
"""


def ensure_skill_files(stash_dir: Path) -> None:
    skills_dir = stash_dir / "skills"
    skills_dir.mkdir(parents=True, exist_ok=True)

    indexing_path = skills_dir / "indexing_skill.md"
    execution_path = skills_dir / "execution_skill.md"

    if not indexing_path.exists():
        indexing_path.write_text(INDEXING_SKILL, encoding="utf-8")
    if not execution_path.exists():
        execution_path.write_text(EXECUTION_SKILL, encoding="utf-8")


def load_skill_bundle(stash_dir: Path) -> str:
    skills_dir = stash_dir / "skills"
    parts: list[str] = []
    for path in sorted(skills_dir.glob("*.md")):
        try:
            parts.append(path.read_text(encoding="utf-8"))
        except OSError:
            continue
    return "\n\n".join(parts)
