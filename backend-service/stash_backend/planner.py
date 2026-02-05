from __future__ import annotations

import json
import logging
import re
import shlex
import subprocess
import time
from typing import Any
from urllib import error, request

from .codex import ALLOWED_PREFIXES, parse_tagged_commands
from .config import Settings
from .integrations import is_codex_model_config_error, resolve_binary
from .runtime_config import RuntimeConfig, RuntimeConfigStore
from .types import PlanResult

MAX_HISTORY_ITEMS = 10
MAX_HISTORY_CONTENT_CHARS = 500
MAX_SKILLS_CHARS = 7000
RETRY_HISTORY_ITEMS = 6
RETRY_HISTORY_CONTENT_CHARS = 300
RETRY_SKILLS_CHARS = 2500
CODEX_PLANNER_REASONING_EFFORT = "medium"
CODEX_SYNTHESIS_REASONING_EFFORT = "low"
MAX_SYNTHESIS_TIMEOUT_SECONDS = 20

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

READ_HINT_KEYWORDS = (
    "read",
    "open",
    "show",
    "view",
    "summarize",
    "analyse",
    "analyze",
    "review",
)

FILE_REF_RE = re.compile(r"(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.[A-Za-z0-9]{1,12}")
CODEX_CMD_BLOCK_RE = re.compile(r"<codex_cmd(?:\s+[^>]*)?>[\s\S]*?</codex_cmd>", flags=re.IGNORECASE)
STASH_FILE_TAG_RE = re.compile(r"<stash_file>\s*([^<]+?)\s*</stash_file>", flags=re.IGNORECASE)

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

    def _strip_codex_cmd_blocks(self, text: str) -> str:
        stripped = CODEX_CMD_BLOCK_RE.sub("", text)
        stripped = re.sub(r"\n{3,}", "\n\n", stripped)
        return stripped.strip()

    def sanitize_assistant_text(self, text: str) -> str:
        return self._strip_codex_cmd_blocks(text).strip()

    def _extract_stash_file_tags(self, text: str) -> list[str]:
        tags: list[str] = []
        seen: set[str] = set()
        for match in STASH_FILE_TAG_RE.finditer(text):
            candidate = match.group(1).strip()
            lowered = candidate.lower()
            if not candidate or lowered in seen:
                continue
            seen.add(lowered)
            tags.append(candidate)
        return tags

    def _append_output_file_tags(self, text: str, output_files: list[str]) -> str:
        if not output_files:
            return text.strip()

        known = set(path.lower() for path in self._extract_stash_file_tags(text))
        missing = [path for path in output_files if path.lower() not in known]
        if not missing:
            return text.strip()

        suffix = "Output files:\n" + "\n".join(f"- <stash_file>{path}</stash_file>" for path in missing[:10])
        base = text.strip()
        if base:
            return f"{base}\n\n{suffix}"
        return suffix

    def _extract_requested_paths(self, user_message: str) -> list[str]:
        paths: list[str] = []
        seen: set[str] = set()
        for match in FILE_REF_RE.findall(user_message):
            cleaned = match.strip().strip("`\"'").lstrip("@")
            lowered = cleaned.lower()
            if not cleaned or lowered in seen:
                continue
            seen.add(lowered)
            paths.append(cleaned)
        return paths

    def _pick_output_candidate(
        self,
        *,
        user_message: str,
        tool_results: list[dict[str, Any]],
    ) -> dict[str, Any] | None:
        requested_paths = [path.lower() for path in self._extract_requested_paths(user_message)]
        best: tuple[int, int, dict[str, Any]] | None = None

        for item in tool_results:
            exit_code = int(item.get("exit_code") or 0)
            if exit_code != 0:
                continue
            stdout = str(item.get("stdout", "")).strip()
            if not stdout:
                continue

            cmd = str(item.get("cmd", ""))
            cmd_lower = cmd.lower()
            step_index = int(item.get("step_index") or 0)

            score = 0
            if requested_paths and any(path in cmd_lower for path in requested_paths):
                score += 100
            elif requested_paths:
                stdout_head = stdout[:800].lower()
                if any(path in stdout_head for path in requested_paths):
                    score += 50

            if any(token in cmd_lower for token in ("cat ", "sed ", "rg ", "grep ", "python", "python3")):
                score += 20

            if len(stdout) > 80:
                score += 10

            if best is None or (score, step_index) >= (best[0], best[1]):
                best = (score, step_index, item)

        return best[2] if best else None

    def _naive_bullet_summary(self, text: str, *, max_bullets: int = 5) -> str:
        normalized = text.replace("\r\n", "\n").strip()
        sentences = [s.strip() for s in re.split(r"(?<=[.!?])\s+|\n+", normalized) if s.strip()]
        bullets: list[str] = []
        seen: set[str] = set()

        for sentence in sentences:
            compact = re.sub(r"\s+", " ", sentence)
            if len(compact) < 30:
                continue
            key = compact.lower()
            if key in seen:
                continue
            seen.add(key)
            bullets.append(f"- {compact[:220]}")
            if len(bullets) >= max_bullets:
                break

        if bullets:
            return "\n".join(bullets)

        preview_lines = [line.strip() for line in normalized.splitlines() if line.strip()]
        if not preview_lines:
            return "- No readable content was produced."

        fallback = " ".join(preview_lines[:3])
        fallback = re.sub(r"\s+", " ", fallback)
        return f"- {fallback[:260]}"

    def _local_tool_response_fallback(self, *, user_message: str, tool_results: list[dict[str, Any]]) -> str | None:
        if not tool_results:
            return None

        failures = [item for item in tool_results if int(item.get("exit_code") or 0) != 0]
        selected = self._pick_output_candidate(user_message=user_message, tool_results=tool_results)

        if not selected:
            if failures:
                first_failure = failures[0]
                failure_detail = str(first_failure.get("stderr") or "").strip() or "Command failed without stderr output."
                return (
                    "I ran the commands but could not produce readable output.\n"
                    f"Failure: {failure_detail[:500]}"
                )
            return None

        stdout = str(selected.get("stdout") or "").strip()
        if not stdout:
            return None

        request_lower = user_message.lower()
        needs_summary = any(keyword in request_lower for keyword in ("summary", "summarize", "summarise"))
        asks_for_contents = any(
            keyword in request_lower
            for keyword in ("what is in", "what's in", "tell me", "read", "show", "contents")
        )

        if needs_summary:
            return "Summary based on the extracted output:\n" + self._naive_bullet_summary(stdout)

        preview = stdout[:4000]
        if asks_for_contents:
            if len(stdout) > len(preview):
                preview += "\n\n... (truncated)"
            return "Here is what I found:\n\n" + preview

        return "Execution completed. Relevant output:\n\n" + preview

    def _build_response_prompt(
        self,
        *,
        user_message: str,
        planner_text: str,
        tool_results: list[dict[str, Any]],
        output_files: list[str],
    ) -> str:
        trimmed_results: list[dict[str, Any]] = []
        for item in tool_results[-8:]:
            trimmed_results.append(
                {
                    "step_index": item.get("step_index"),
                    "status": item.get("status"),
                    "exit_code": item.get("exit_code"),
                    "cmd": str(item.get("cmd", ""))[:280],
                    "stdout": str(item.get("stdout", ""))[:2600],
                    "stderr": str(item.get("stderr", ""))[:900],
                }
            )

        return (
            "You are Stash assistant.\n"
            "Write the final answer to the user based on completed local command results.\n"
            "Do not include <codex_cmd> blocks.\n"
            "Do not include raw execution audit headers like 'Execution summary'.\n"
            "If results contain file content, summarize it directly for the user.\n"
            "If a step failed, mention the failure and what to do next.\n"
            "If the run produced output files, include each one as `<stash_file>relative/path.ext</stash_file>`.\n"
            "Keep the response concise but useful.\n\n"
            f"Original user request:\n{user_message}\n\n"
            f"Planner draft text:\n{self._strip_codex_cmd_blocks(planner_text)[:2400]}\n\n"
            f"Detected output files:\n{json.dumps(output_files[:10], ensure_ascii=True)}\n\n"
            f"Command result JSON:\n{json.dumps(trimmed_results, ensure_ascii=True)}\n"
        )

    def _run_openai_text_prompt(self, *, prompt: str, runtime: RuntimeConfig) -> str | None:
        if not self._openai_available(runtime=runtime):
            return None

        payload = {"model": runtime.openai_model, "input": prompt}
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
            logger.warning("OpenAI response synthesis failed status=%s detail=%s", exc.code, detail[:500])
            return None
        except Exception:
            logger.exception("OpenAI response synthesis failed")
            return None

        try:
            response_json = json.loads(response_text)
        except json.JSONDecodeError:
            logger.warning("OpenAI response synthesis returned non-JSON payload")
            return None

        text = self._extract_openai_output_text(response_json)
        if not text:
            return None
        return text.strip()

    def _run_codex_text_prompt(
        self,
        *,
        prompt: str,
        runtime: RuntimeConfig,
        project_summary: dict[str, Any],
        timeout_seconds: int,
        attempt_label: str,
    ) -> str | None:
        if not self._codex_available(runtime=runtime):
            return None

        planning_cwd = str(project_summary.get("root_path") or ".")
        resolved_codex = resolve_binary(runtime.codex_bin)
        if not resolved_codex:
            return None

        base_cmdline = [
            resolved_codex,
            "exec",
            "--json",
            "--skip-git-repo-check",
            "-s",
            "read-only",
            "-C",
            planning_cwd,
            "-c",
            f'reasoning.effort="{CODEX_PLANNER_REASONING_EFFORT}"',
        ]
        cmdline = list(base_cmdline)
        if runtime.codex_planner_model:
            cmdline.extend(["-m", runtime.codex_planner_model])
        cmdline.extend(["-c", f'reasoning.effort="{CODEX_SYNTHESIS_REASONING_EFFORT}"'])
        cmdline.append("-")

        try:
            proc = subprocess.run(
                cmdline,
                input=prompt,
                text=True,
                capture_output=True,
                timeout=timeout_seconds,
                check=False,
            )
        except Exception:
            logger.exception("Codex response synthesis subprocess failed")
            return None

        if proc.returncode != 0:
            stderr_preview = ((proc.stderr or "") + "\n" + (proc.stdout or "")).strip()[:1200]
            logger.warning(
                "Codex response synthesis failed exit_code=%s attempt=%s stderr=%r",
                proc.returncode,
                attempt_label,
                stderr_preview,
            )
            if runtime.codex_planner_model and is_codex_model_config_error(stderr_preview):
                if self.runtime_config_store is not None:
                    try:
                        self.runtime_config_store.update(codex_planner_model="")
                    except Exception:
                        logger.exception("Could not persist codex planner model reset after synthesis failure")
                try:
                    proc = subprocess.run(
                        [*base_cmdline, "-"],
                        input=prompt,
                        text=True,
                        capture_output=True,
                        timeout=timeout_seconds,
                        check=False,
                    )
                except Exception:
                    logger.exception("Codex response synthesis retry subprocess failed")
                    return None
                if proc.returncode != 0:
                    return None
            else:
                return None

        message = self._extract_agent_message_from_jsonl(proc.stdout or "")
        if message:
            return message.strip()
        output = (proc.stdout or "").strip()
        return output or None

    def synthesize_response(
        self,
        *,
        user_message: str,
        planner_text: str,
        project_summary: dict[str, Any],
        tool_results: list[dict[str, Any]],
        output_files: list[str] | None = None,
    ) -> str | None:
        if not tool_results:
            return None

        runtime = self._runtime_config()
        normalized_output_files = [path.strip() for path in (output_files or []) if path.strip()]
        prompt = self._build_response_prompt(
            user_message=user_message,
            planner_text=planner_text,
            tool_results=tool_results,
            output_files=normalized_output_files,
        )

        backend_order = ["codex", "openai"]
        if runtime.planner_backend == "openai_api":
            backend_order = ["openai", "codex"]

        for backend in backend_order:
            text: str | None
            if backend == "openai":
                text = self._run_openai_text_prompt(prompt=prompt, runtime=runtime)
            else:
                text = self._run_codex_text_prompt(
                    prompt=prompt,
                    runtime=runtime,
                    project_summary=project_summary,
                    timeout_seconds=min(MAX_SYNTHESIS_TIMEOUT_SECONDS, runtime.planner_timeout_seconds),
                    attempt_label=backend,
                )

            if not text:
                continue
            cleaned = self.sanitize_assistant_text(text)
            if cleaned:
                return self._append_output_file_tags(cleaned, normalized_output_files)

        fallback = self._local_tool_response_fallback(user_message=user_message, tool_results=tool_results)
        if fallback:
            cleaned_fallback = self.sanitize_assistant_text(fallback)
            return self._append_output_file_tags(cleaned_fallback, normalized_output_files)

        return None

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
                "content": self._strip_codex_cmd_blocks(str(item.get("content", "")))[:max_history_content_chars],
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
            "- Prefer direct python/python3 commands with already-installed packages; avoid `uv run --with ...` unless the user explicitly asks for uv-managed ephemeral dependencies.\n"
            "- Never use sudo, rm -rf, git reset --hard, or destructive commands.\n"
            f"- For changes intended to affect project files, set cwd to this exact project root path: {project_root}.\n"
            "- Keep commands inside the project/worktree context.\n"
            "- Output strategy: decide whether output should be inline chat text or a project file.\n"
            "- Prefer inline chat output for quick questions, explanations, and short answers.\n"
            "- Create a project file only when it improves usability: user explicitly asks to save/export/create a file, requests a persistent artifact, asks for a reusable draft/template/report, or the result is long/structured enough that a file is better.\n"
            "- When a file is needed, pick the best format for the task (for example: .txt/.md for narrative notes, .csv/.xlsx for tabular data, .docx for formal docs, .pdf/.pptx only when explicitly requested or clearly required).\n"
            "- If you create files, include each file path in assistant text as `<stash_file>relative/path.ext</stash_file>`. If no file is created, do not emit stash_file tags.\n"
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

        base_cmdline = [
            resolved_codex,
            "exec",
            "--json",
            "--skip-git-repo-check",
            "-s",
            "read-only",
            "-C",
            planning_cwd,
            "-c",
            f'reasoning.effort="{CODEX_PLANNER_REASONING_EFFORT}"',
        ]
        cmdline = list(base_cmdline)
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
            stderr_preview = ((proc.stderr or "") + "\n" + (proc.stdout or "")).strip()[:1200]
            logger.warning(
                "Codex planner returned non-zero exit code=%s attempt=%s stderr=%r",
                proc.returncode,
                attempt_label,
                stderr_preview,
            )

            if runtime.codex_planner_model and is_codex_model_config_error(stderr_preview):
                logger.warning(
                    "Codex planner model '%s' is incompatible in this runtime. Retrying without explicit model.",
                    runtime.codex_planner_model,
                )
                if self.runtime_config_store is not None:
                    try:
                        self.runtime_config_store.update(codex_planner_model="")
                    except Exception:
                        logger.exception("Could not persist codex planner model reset")

                cmdline_no_model = [*base_cmdline, "-"]
                try:
                    proc = subprocess.run(
                        cmdline_no_model,
                        input=prompt,
                        text=True,
                        capture_output=True,
                        timeout=planner_timeout,
                        check=False,
                    )
                except subprocess.TimeoutExpired:
                    logger.error(
                        "Codex planner timed out after model reset attempt=%s timeout_seconds=%s",
                        attempt_label,
                        planner_timeout,
                    )
                    return None
                except Exception:
                    logger.exception("Codex planner subprocess failed after model reset")
                    return None

                if proc.returncode != 0:
                    stderr_preview = ((proc.stderr or "") + "\n" + (proc.stdout or "")).strip()[:1200]
                    logger.warning(
                        "Codex planner no-model retry failed exit_code=%s attempt=%s stderr=%r",
                        proc.returncode,
                        attempt_label,
                        stderr_preview,
                    )
                    return None
            else:
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

    def _heuristic_read_plan(self, *, user_message: str, project_summary: dict[str, Any]) -> PlanResult | None:
        lowered = user_message.lower()
        if not any(keyword in lowered for keyword in READ_HINT_KEYWORDS):
            return None

        for match in FILE_REF_RE.findall(user_message):
            cleaned = match.strip().strip("`\"'")
            if not cleaned or cleaned.startswith("http://") or cleaned.startswith("https://"):
                continue
            quoted_path = shlex.quote(cleaned)
            project_root = str(project_summary.get("root_path") or ".")
            planner_text = (
                "Planner fallback recovery: reading the requested file directly.\n"
                "<codex_cmd>\n"
                "worktree: main\n"
                f"cwd: {project_root}\n"
                f"cmd: cat {quoted_path}\n"
                "</codex_cmd>"
            )
            commands = parse_tagged_commands(planner_text)
            if commands:
                logger.info("Planner selected heuristic read fallback path file=%s", cleaned)
                return PlanResult(planner_text=planner_text, commands=commands)
        return None

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

        heuristic = self._heuristic_read_plan(user_message=user_message, project_summary=project_summary)
        if heuristic is not None:
            return heuristic

        if runtime.planner_backend == "openai_api" and not self._openai_available(runtime=runtime):
            fallback_hint = "Open AI setup and add your OpenAI API key."
        elif not self._codex_available(runtime=runtime) and not self._openai_available(runtime=runtime):
            fallback_hint = "Verify Codex CLI login, or add an OpenAI API key in AI setup."
        elif not self._codex_available(runtime=runtime):
            fallback_hint = "Verify Codex CLI installation and login in AI setup."
        else:
            fallback_hint = "Try again or rephrase the request."

        fallback = f"Planner fallback: could not generate an execution plan. {fallback_hint}"
        logger.error("Planner fallback reached: no commands generated")
        return PlanResult(planner_text=fallback, commands=[])
