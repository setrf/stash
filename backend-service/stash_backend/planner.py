from __future__ import annotations

import json
import subprocess
from typing import Any

from .codex import parse_tagged_commands
from .config import Settings
from .types import PlanResult


class Planner:
    def __init__(self, settings: Settings):
        self.settings = settings

    def _run_external_planner(self, payload: dict[str, Any]) -> str | None:
        if not self.settings.planner_cmd:
            return None

        try:
            proc = subprocess.run(
                ["bash", "-lc", self.settings.planner_cmd],
                input=json.dumps(payload),
                text=True,
                capture_output=True,
                timeout=90,
                check=False,
            )
        except Exception:
            return None

        if proc.returncode != 0:
            return None

        output = (proc.stdout or "").strip()
        return output if output else None

    def plan(
        self,
        *,
        user_message: str,
        conversation_history: list[dict[str, Any]],
        skill_bundle: str,
        project_summary: dict[str, Any],
    ) -> PlanResult:
        direct_commands = parse_tagged_commands(user_message)
        if direct_commands:
            return PlanResult(
                planner_text=f"Executing {len(direct_commands)} tagged command(s) from user input.",
                commands=direct_commands,
            )

        external_payload = {
            "project": project_summary,
            "history": conversation_history[-20:],
            "skills": skill_bundle,
            "user_message": user_message,
            "instruction": (
                "Return guidance text and optional <codex_cmd> blocks. "
                "Use only safe filesystem/coding commands."
            ),
        }

        external_text = self._run_external_planner(external_payload)
        if external_text:
            commands = parse_tagged_commands(external_text)
            return PlanResult(planner_text=external_text, commands=commands)

        fallback = (
            "Planner fallback: no external GPT planner configured and no tagged commands found. "
            "Add one or more <codex_cmd> blocks to run filesystem/code tasks, or provide a planner via STASH_PLANNER_CMD."
        )
        return PlanResult(planner_text=fallback, commands=[])
