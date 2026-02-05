from __future__ import annotations

import json
import logging
import subprocess
import time
from typing import Any
from urllib import error, request

from .codex import ALLOWED_PREFIXES, parse_tagged_commands
from .config import Settings
from .integrations import resolve_binary
from .runtime_config import RuntimeConfig, RuntimeConfigStore
from .types import PlanResult

MAX_HISTORY_ITEMS = 20
MAX_HISTORY_CONTENT_CHARS = 1200
MAX_SKILLS_CHARS = 12000
RETRY_HISTORY_ITEMS = 6
RETRY_HISTORY_CONTENT_CHARS = 300
RETRY_SKILLS_CHARS = 2500

ACTION_KEYWORDS = (
    "create",
    "write",
    "generate",
    "make",
    "build",
    "update",
    "edit",
    "fix",
    "organize",
    "move",
    "rename",
    "read",
    "analyze",
    "summarize",
)

logger = logging.getLogger(__name__)


class Planner:
    def __init__(self, settings: Settings, runtime_config_store: RuntimeConfigStore | None = None):
        self.settings = settings
        self.runtime_config_store = runtime_config_store

    def _runtime_config(self) -> RuntimeConfig:
        if self.runtime_config_store is not None:
            return self.runtime_config_store.get()
        return RuntimeConfig.from_settings(self.settings)

    def _run_external_planner(self, payload: dict[str, Any], *, runtime: RuntimeConfig) -> str | None:
        if not runtime.planner_cmd:
            return None

        try:
            proc = subprocess.run(
                ["bash", "-lc", runtime.planner_cmd],
                input=json.dumps(payload),
                text=True,
                capture_output=True,
                timeout=90,
                check=False,
            )
        except Exception:
            logger.exception("External planner command failed to start")
            return None

        if proc.returncode != 0:
            logger.warning("External planner returned non-zero exit code=%s", proc.returncode)
            return None

        output = (proc.stdout or "").strip()
        logger.info("External planner produced output chars=%s", len(output))
        return output if output else None

    def _openai_available(self, *, runtime: RuntimeConfig) -> bool:
        return bool(runtime.openai_api_key and runtime.openai_model)

    def _codex_available(self, *, runtime: RuntimeConfig) -> bool:
        return resolve_binary(runtime.codex_bin) is not None

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

    def _extract_openai_output_text(self, payload: dict[str, Any]) -> str | None:
        direct = payload.get("output_text")
        if isinstance(direct, str) and direct.strip():
            return direct.strip()

        output = payload.get("output")
        if not isinstance(output, list):
            return None

        chunks: list[str] = []
        for item in output:
            if not isinstance(item, dict):
                continue
            content = item.get("content")
            if not isinstance(content, list):
                continue
            for part in content:
                if not isinstance(part, dict):
                    continue
                text = part.get("text")
                if isinstance(text, str) and text.strip():
                    chunks.append(text.strip())

        if not chunks:
            return None
        return "\n\n".join(chunks)

    def _build_planner_prompt(
        self,
        *,
        user_message: str,
        conversation_history: list[dict[str, Any]],
        skill_bundle: str,
        project_summary: dict[str, Any],
        max_history_items: int,
        max_history_content_chars: int,
        max_skills_chars: int,
        require_commands: bool,
    ) -> str:
        normalized_history = [
            {
                "role": item.get("role"),
                "content": str(item.get("content", ""))[:max_history_content_chars],
                "created_at": item.get("created_at"),
            }
            for item in conversation_history[-max_history_items:]
        ]
        allowed_prefixes = ", ".join(sorted(ALLOWED_PREFIXES))
        truncated_skills = skill_bundle[:max_skills_chars]
        project_root = str(project_summary.get("root_path") or ".")
        final_rule = (
            "- Return at least one <codex_cmd> block."
            if require_commands
            else "- If no commands are needed, return only assistant text."
        )

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
            f"{final_rule}\n\n"
            f"Project summary JSON:\n{json.dumps(project_summary, ensure_ascii=True)}\n\n"
            f"Recent conversation JSON:\n{json.dumps(normalized_history, ensure_ascii=True)}\n\n"
            f"Skills context:\n{truncated_skills}\n\n"
            f"User message:\n{user_message}\n"
        )

    def _run_openai_planner(
        self,
        *,
        user_message: str,
        conversation_history: list[dict[str, Any]],
        skill_bundle: str,
        project_summary: dict[str, Any],
        runtime: RuntimeConfig,
        max_history_items: int = MAX_HISTORY_ITEMS,
        max_history_content_chars: int = MAX_HISTORY_CONTENT_CHARS,
        max_skills_chars: int = MAX_SKILLS_CHARS,
        require_commands: bool = False,
    ) -> str | None:
        if not self._openai_available(runtime=runtime):
            return None

        planner_prompt = self._build_planner_prompt(
            user_message=user_message,
            conversation_history=conversation_history,
            skill_bundle=skill_bundle,
            project_summary=project_summary,
            max_history_items=max_history_items,
            max_history_content_chars=max_history_content_chars,
            max_skills_chars=max_skills_chars,
            require_commands=require_commands,
        )
        payload = {
            "model": runtime.openai_model,
            "input": planner_prompt,
        }
        body = json.dumps(payload).encode("utf-8")
        url = f"{runtime.openai_base_url.rstrip('/')}/responses"
        headers = {
            "Authorization": f"Bearer {runtime.openai_api_key}",
            "Content-Type": "application/json",
        }
        req = request.Request(url, data=body, headers=headers, method="POST")

        try:
            with request.urlopen(req, timeout=runtime.openai_timeout_seconds) as response:
                response_text = response.read().decode("utf-8", errors="replace")
        except error.HTTPError as exc:
            detail = exc.read().decode("utf-8", errors="replace")
            logger.warning(
                "OpenAI planner request failed status=%s detail=%s",
                exc.code,
                detail[:500],
            )
            return None
        except error.URLError:
            logger.exception("OpenAI planner request failed")
            return None
        except Exception:
            logger.exception("OpenAI planner request crashed")
            return None

        try:
            response_json = json.loads(response_text)
        except json.JSONDecodeError:
            logger.warning("OpenAI planner returned non-JSON response chars=%s", len(response_text))
            return None

        planner_text = self._extract_openai_output_text(response_json)
        if not planner_text:
            logger.warning("OpenAI planner returned empty response payload")
            return None

        logger.info(
            "OpenAI planner produced response chars=%s commands=%s",
            len(planner_text),
            len(parse_tagged_commands(planner_text)),
        )
        return planner_text

    def _run_codex_planner(
        self,
        *,
        user_message: str,
        conversation_history: list[dict[str, Any]],
        skill_bundle: str,
        project_summary: dict[str, Any],
        runtime: RuntimeConfig,
        max_history_items: int = MAX_HISTORY_ITEMS,
        max_history_content_chars: int = MAX_HISTORY_CONTENT_CHARS,
        max_skills_chars: int = MAX_SKILLS_CHARS,
        require_commands: bool = False,
        timeout_seconds: int | None = None,
        attempt_label: str = "primary",
    ) -> str | None:
        if not self._codex_available(runtime=runtime):
            logger.warning("Codex planner unavailable: binary '%s' not found", runtime.codex_bin)
            return None

        planning_cwd = str(project_summary.get("root_path") or ".")
        planner_timeout = timeout_seconds or runtime.planner_timeout_seconds
        prompt = self._build_planner_prompt(
            user_message=user_message,
            conversation_history=conversation_history,
            skill_bundle=skill_bundle,
            project_summary=project_summary,
            max_history_items=max_history_items,
            max_history_content_chars=max_history_content_chars,
            max_skills_chars=max_skills_chars,
            require_commands=require_commands,
        )

        resolved_codex = resolve_binary(runtime.codex_bin)
        if not resolved_codex:
            logger.warning("Codex planner unavailable: binary '%s' not found", runtime.codex_bin)
            return None

        cmdline = [
            resolved_codex,
            "exec",
            "--json",
            "--skip-git-repo-check",
            "-s",
            "read-only",
            "-C",
            planning_cwd,
        ]
        if runtime.codex_planner_model:
            cmdline.extend(["-m", runtime.codex_planner_model])
        cmdline.append("-")

        try:
            proc = subprocess.run(
                cmdline,
                input=prompt,
                text=True,
                capture_output=True,
                timeout=planner_timeout,
                check=False,
            )
        except subprocess.TimeoutExpired:
            logger.error(
                "Codex planner timed out attempt=%s timeout_seconds=%s",
                attempt_label,
                planner_timeout,
            )
            return None
        except Exception:
            logger.exception("Codex planner subprocess failed")
            return None

        if proc.returncode != 0:
            logger.warning(
                "Codex planner returned non-zero exit code=%s attempt=%s",
                proc.returncode,
                attempt_label,
            )
            return None

        jsonl_message = self._extract_agent_message_from_jsonl(proc.stdout or "")
        if jsonl_message:
            logger.info(
                "Codex planner produced agent message attempt=%s chars=%s commands=%s",
                attempt_label,
                len(jsonl_message),
                len(parse_tagged_commands(jsonl_message)),
            )
            return jsonl_message

        output = (proc.stdout or "").strip()
        logger.info(
            "Codex planner produced raw stdout attempt=%s chars=%s commands=%s",
            attempt_label,
            len(output),
            len(parse_tagged_commands(output)),
        )
        return output if output else None

    def _is_actionable_request(self, user_message: str) -> bool:
        lowered = user_message.lower()
        return any(keyword in lowered for keyword in ACTION_KEYWORDS)

    def _attempt_openai(
        self,
        *,
        actionable: bool,
        user_message: str,
        conversation_history: list[dict[str, Any]],
        skill_bundle: str,
        project_summary: dict[str, Any],
        runtime: RuntimeConfig,
    ) -> PlanResult | None:
        openai_started = time.monotonic()
        openai_text = self._run_openai_planner(
            user_message=user_message,
            conversation_history=conversation_history,
            skill_bundle=skill_bundle,
            project_summary=project_summary,
            runtime=runtime,
            require_commands=actionable,
        )
        logger.info("OpenAI planner attempt duration_ms=%s", int((time.monotonic() - openai_started) * 1000))
        if not openai_text:
            return None
        commands = parse_tagged_commands(openai_text)
        if commands or not actionable:
            logger.info("Planner selected OpenAI planner path commands=%s", len(commands))
            return PlanResult(planner_text=openai_text, commands=commands)
        logger.warning("OpenAI planner returned no commands for actionable request")
        return None

    def _attempt_codex(
        self,
        *,
        actionable: bool,
        user_message: str,
        conversation_history: list[dict[str, Any]],
        skill_bundle: str,
        project_summary: dict[str, Any],
        runtime: RuntimeConfig,
    ) -> PlanResult | None:
        codex_started = time.monotonic()
        codex_text = self._run_codex_planner(
            user_message=user_message,
            conversation_history=conversation_history,
            skill_bundle=skill_bundle,
            project_summary=project_summary,
            runtime=runtime,
            require_commands=actionable,
            attempt_label="primary",
        )
        logger.info("Codex planner primary attempt duration_ms=%s", int((time.monotonic() - codex_started) * 1000))
        if codex_text:
            commands = parse_tagged_commands(codex_text)
            if commands or not actionable:
                logger.info("Planner selected codex planner path commands=%s", len(commands))
                return PlanResult(planner_text=codex_text, commands=commands)
            logger.warning("Codex planner primary attempt produced no commands for actionable request")

        retry_timeout = max(30, min(runtime.planner_timeout_seconds, 60))
        retry_started = time.monotonic()
        codex_retry_text = self._run_codex_planner(
            user_message=user_message,
            conversation_history=conversation_history,
            skill_bundle=skill_bundle,
            project_summary=project_summary,
            runtime=runtime,
            max_history_items=RETRY_HISTORY_ITEMS,
            max_history_content_chars=RETRY_HISTORY_CONTENT_CHARS,
            max_skills_chars=RETRY_SKILLS_CHARS,
            require_commands=actionable,
            timeout_seconds=retry_timeout,
            attempt_label="retry",
        )
        logger.info("Codex planner retry attempt duration_ms=%s", int((time.monotonic() - retry_started) * 1000))
        if not codex_retry_text:
            return None
        commands = parse_tagged_commands(codex_retry_text)
        if commands or not actionable:
            logger.info("Planner selected codex retry path commands=%s", len(commands))
            return PlanResult(planner_text=codex_retry_text, commands=commands)
        logger.warning("Codex planner retry produced no commands for actionable request")
        return None

    def plan(
        self,
        *,
        user_message: str,
        conversation_history: list[dict[str, Any]],
        skill_bundle: str,
        project_summary: dict[str, Any],
    ) -> PlanResult:
        runtime = self._runtime_config()
        direct_commands = parse_tagged_commands(user_message)
        if direct_commands:
            logger.info("Planner using direct tagged commands count=%s", len(direct_commands))
            return PlanResult(
                planner_text=f"Executing {len(direct_commands)} tagged command(s) from user input.",
                commands=direct_commands,
            )

        actionable = self._is_actionable_request(user_message)

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
        external_text = self._run_external_planner(external_payload, runtime=runtime)
        if external_text:
            commands = parse_tagged_commands(external_text)
            if commands or not actionable:
                logger.info("Planner selected external planner path commands=%s", len(commands))
                return PlanResult(planner_text=external_text, commands=commands)
            logger.warning("External planner returned no commands for actionable request")

        # Use GPT through Codex CLI first whenever possible.
        planner_order = ["codex", "openai"]
        if runtime.planner_backend == "openai_api":
            planner_order = ["openai", "codex"]

        for backend in planner_order:
            if backend == "openai":
                result = self._attempt_openai(
                    actionable=actionable,
                    user_message=user_message,
                    conversation_history=conversation_history,
                    skill_bundle=skill_bundle,
                    project_summary=project_summary,
                    runtime=runtime,
                )
            else:
                result = self._attempt_codex(
                    actionable=actionable,
                    user_message=user_message,
                    conversation_history=conversation_history,
                    skill_bundle=skill_bundle,
                    project_summary=project_summary,
                    runtime=runtime,
                )
            if result is not None:
                return result

        fallback = (
            "Planner fallback: could not generate an execution plan. "
            "Open AI setup in Stash and verify Codex CLI login, then configure OpenAI API key as fallback."
        )
        logger.error("Planner fallback reached: no commands generated")
        return PlanResult(planner_text=fallback, commands=[])
