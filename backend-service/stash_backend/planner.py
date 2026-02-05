from __future__ import annotations

import json
import shutil
import subprocess
from typing import Any

from .codex import ALLOWED_PREFIXES, parse_tagged_commands
from .config import Settings
from .types import PlanResult

MAX_HISTORY_ITEMS = 20
MAX_HISTORY_CONTENT_CHARS = 1200
MAX_SKILLS_CHARS = 12000


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

    def _codex_available(self) -> bool:
        return shutil.which(self.settings.codex_bin) is not None

    def _extract_agent_message_from_jsonl(self, output: str) -> str | None:
        last_message = ""
        for raw_line in output.splitlines():
            line = raw_line.strip()
            if not line or not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue

            if event.get("type") != "item.completed":
                continue
            item = event.get("item") or {}
            if item.get("type") != "agent_message":
                continue
            text = item.get("text")
            if isinstance(text, str):
                last_message = text.strip()
        return last_message or None

    def _build_codex_prompt(
        self,
        *,
        user_message: str,
        conversation_history: list[dict[str, Any]],
        skill_bundle: str,
        project_summary: dict[str, Any],
    ) -> str:
        normalized_history = [
            {
                "role": item.get("role"),
                "content": str(item.get("content", ""))[:MAX_HISTORY_CONTENT_CHARS],
                "created_at": item.get("created_at"),
            }
            for item in conversation_history[-MAX_HISTORY_ITEMS:]
        ]
        allowed_prefixes = ", ".join(sorted(ALLOWED_PREFIXES))
        truncated_skills = skill_bundle[:MAX_SKILLS_CHARS]
        project_root = str(project_summary.get("root_path") or ".")

        return (
            "You are the Stash planner.\n"
            "Convert the user request into a safe execution plan for a local command runner.\n"
            "Return plain text only. Do not use markdown code fences.\n\n"
            "Output format:\n"
            "1) Short assistant response to user (1-4 sentences).\n"
            "2) Zero or more <codex_cmd> blocks using this exact structure:\n"
            "<codex_cmd>\n"
            "worktree: <short-label>\n"
            "cwd: <relative-path-or-.>\n"
            "cmd: <single-shell-command>\n"
            "</codex_cmd>\n\n"
            "Rules:\n"
            "- Use at most 8 commands.\n"
            "- One shell command per block.\n"
            f"- Allowed command prefixes only: {allowed_prefixes}.\n"
            "- Never use sudo, rm -rf, git reset --hard, or destructive commands.\n"
            f"- For changes intended to affect project files, set cwd to this exact project root path: {project_root}.\n"
            "- Keep commands inside the project/worktree context.\n"
            "- If no commands are needed, return only assistant text.\n\n"
            f"Project summary JSON:\n{json.dumps(project_summary, ensure_ascii=True)}\n\n"
            f"Recent conversation JSON:\n{json.dumps(normalized_history, ensure_ascii=True)}\n\n"
            f"Skills context:\n{truncated_skills}\n\n"
            f"User message:\n{user_message}\n"
        )

    def _run_codex_planner(
        self,
        *,
        user_message: str,
        conversation_history: list[dict[str, Any]],
        skill_bundle: str,
        project_summary: dict[str, Any],
    ) -> str | None:
        if not self._codex_available():
            return None

        planning_cwd = str(project_summary.get("root_path") or ".")
        prompt = self._build_codex_prompt(
            user_message=user_message,
            conversation_history=conversation_history,
            skill_bundle=skill_bundle,
            project_summary=project_summary,
        )

        cmdline = [
            self.settings.codex_bin,
            "exec",
            "--json",
            "--skip-git-repo-check",
            "-s",
            "read-only",
            "-C",
            planning_cwd,
            "-",
        ]

        try:
            proc = subprocess.run(
                cmdline,
                input=prompt,
                text=True,
                capture_output=True,
                timeout=self.settings.planner_timeout_seconds,
                check=False,
            )
        except Exception:
            return None

        if proc.returncode != 0:
            return None

        jsonl_message = self._extract_agent_message_from_jsonl(proc.stdout or "")
        if jsonl_message:
            return jsonl_message

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

        codex_text = self._run_codex_planner(
            user_message=user_message,
            conversation_history=conversation_history,
            skill_bundle=skill_bundle,
            project_summary=project_summary,
        )
        if codex_text:
            commands = parse_tagged_commands(codex_text)
            return PlanResult(planner_text=codex_text, commands=commands)

        fallback = (
            "Planner fallback: could not generate an execution plan. "
            "Verify Codex CLI is installed and logged in (`codex login status`), "
            "or provide a custom planner via STASH_PLANNER_CMD."
        )
        return PlanResult(planner_text=fallback, commands=[])
