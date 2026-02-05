from __future__ import annotations

import asyncio
import logging
import re
import time
from pathlib import Path
from typing import Any

from .codex import CodexCommandError, CodexExecutor
from .db import ProjectRepository
from .indexer import IndexingService
from .planner import Planner
from .project_store import ProjectStore
from .skills import load_skill_bundle
from .utils import ensure_inside

logger = logging.getLogger(__name__)
FILE_TOKEN_RE = re.compile(
    r"(?:[A-Za-z0-9_.-]+/)*[A-Za-z0-9_.-]+\.(?:txt|md|markdown|csv|tsv|json|ya?ml|xml|html|rtf|docx|xlsx|pdf|log)",
    flags=re.IGNORECASE,
)
REDIRECT_TOKEN_RE = re.compile(r"(?:^|\s)(?:>|>>|1>|2>)\s*(['\"]?)([^\s'\"`]+)\1")
OUTPUT_FLAG_TOKEN_RE = re.compile(r"(?:--output|--out|--file|-o)\s+(['\"]?)([^\s'\"`]+)\1", flags=re.IGNORECASE)
OUTPUT_HINT_RE = re.compile(
    r"(?:output|saved(?:\s+to|\s+as)?|written(?:\s+to)?|created)\s*[:=]?\s*(['\"]?)([^\s'\"`]+)\1",
    flags=re.IGNORECASE,
)
STASH_FILE_TAG_TEMPLATE = "<stash_file>{path}</stash_file>"


class RunOrchestrator:
    def __init__(
        self,
        *,
        project_store: ProjectStore,
        indexer: IndexingService,
        planner: Planner,
        codex: CodexExecutor,
    ) -> None:
        self.project_store = project_store
        self.indexer = indexer
        self.planner = planner
        self.codex = codex
        self._tasks: dict[str, asyncio.Task[None]] = {}

    def _compose_planner_user_message(
        self,
        trigger_message: dict[str, Any],
        *,
        rag_hits: list[dict[str, Any]] | None = None,
    ) -> str:
        content = str(trigger_message.get("content", "")).strip()
        parts = trigger_message.get("parts") or []
        if not isinstance(parts, list):
            return content

        file_blocks: list[str] = []
        for part in parts:
            if not isinstance(part, dict):
                continue
            if str(part.get("type", "")) != "file_context":
                continue
            path = str(part.get("path", "")).strip()
            excerpt = str(part.get("excerpt", "")).strip()
            if not path and not excerpt:
                continue
            block = f"File: {path or '(unknown)'}\n{excerpt}" if excerpt else f"File: {path}"
            file_blocks.append(block[:5000])

        sections: list[str] = [content]
        if file_blocks:
            sections.append(
                "[Mentioned file context]\n"
                + "\n\n".join(file_blocks[:6])
                + "\n[/Mentioned file context]"
            )

        if rag_hits:
            rag_lines: list[str] = []
            for hit in rag_hits[:6]:
                path = str(hit.get("path_or_url") or hit.get("title") or "(unknown)")
                score = float(hit.get("score") or 0.0)
                excerpt = str(hit.get("text") or "").strip().replace("\r\n", "\n")
                if len(excerpt) > 800:
                    excerpt = excerpt[:800] + "... (truncated)"
                rag_lines.append(f"Path: {path}\nScore: {score:.3f}\nExcerpt:\n{excerpt}")
            if rag_lines:
                sections.append("[Indexed context]\n" + "\n\n".join(rag_lines) + "\n[/Indexed context]")

        return "\n\n".join(section for section in sections if section).strip()

    def _resolve_command_base_cwd(self, *, context: Any, command_cwd: str | None) -> Path:
        if command_cwd:
            raw = Path(command_cwd).expanduser()
            if raw.is_absolute():
                candidate = raw.resolve()
            else:
                candidate = (context.root_path / raw).resolve()
            if ensure_inside(context.root_path, candidate):
                return candidate
        return context.root_path.resolve()

    def _extract_command_path_tokens(self, command_text: str) -> set[str]:
        tokens: set[str] = set()
        for match in FILE_TOKEN_RE.finditer(command_text):
            tokens.add(match.group(0))
        for match in REDIRECT_TOKEN_RE.finditer(command_text):
            tokens.add(match.group(2))
        for match in OUTPUT_FLAG_TOKEN_RE.finditer(command_text):
            tokens.add(match.group(2))
        return tokens

    def _extract_runtime_path_tokens(self, text: str) -> set[str]:
        tokens: set[str] = set()
        snippet = text[:6000]
        for match in OUTPUT_HINT_RE.finditer(snippet):
            tokens.add(match.group(2))
        for match in FILE_TOKEN_RE.finditer(snippet):
            start = max(0, match.start() - 24)
            end = min(len(snippet), match.end() + 24)
            window = snippet[start:end].lower()
            if any(marker in window for marker in ("output", "saved", "written", "created")):
                tokens.add(match.group(0))
        return tokens

    def _resolve_candidate_path(self, *, context: Any, cwd: Path, token: str) -> Path | None:
        cleaned = token.strip().strip("`'\"").rstrip(".,:;)")
        if not cleaned or "://" in cleaned:
            return None
        if cleaned.startswith("-") or "@" in cleaned:
            return None

        raw = Path(cleaned).expanduser()
        candidate = raw.resolve() if raw.is_absolute() else (cwd / raw).resolve()
        root = context.root_path.resolve()
        stash_dir = context.stash_dir.resolve()

        if not ensure_inside(root, candidate):
            return None
        if candidate == stash_dir or ensure_inside(stash_dir, candidate):
            return None
        return candidate

    def _file_signature(self, path: Path) -> tuple[int, int] | None:
        try:
            if not path.exists() or not path.is_file():
                return None
            stat = path.stat()
            return (int(stat.st_mtime_ns), int(stat.st_size))
        except OSError:
            return None

    def _capture_output_baseline(self, *, context: Any, cwd: Path, command_text: str) -> dict[str, tuple[int, int] | None]:
        baseline: dict[str, tuple[int, int] | None] = {}
        for token in self._extract_command_path_tokens(command_text):
            resolved = self._resolve_candidate_path(context=context, cwd=cwd, token=token)
            if resolved is None:
                continue
            baseline[str(resolved)] = self._file_signature(resolved)
        return baseline

    def _detect_output_files(
        self,
        *,
        context: Any,
        cwd: Path,
        command_text: str,
        stdout: str,
        stderr: str,
        baseline: dict[str, tuple[int, int] | None],
    ) -> list[str]:
        candidate_tokens = self._extract_command_path_tokens(command_text)
        candidate_tokens.update(self._extract_runtime_path_tokens(stdout))
        candidate_tokens.update(self._extract_runtime_path_tokens(stderr))

        root = context.root_path.resolve()
        discovered: list[str] = []
        seen: set[str] = set()

        for token in candidate_tokens:
            resolved = self._resolve_candidate_path(context=context, cwd=cwd, token=token)
            if resolved is None:
                continue

            current_sig = self._file_signature(resolved)
            if current_sig is None:
                continue

            before_sig = baseline.get(str(resolved))
            if before_sig is not None and before_sig == current_sig:
                continue

            rel = str(resolved.relative_to(root))
            rel_lower = rel.lower()
            if rel_lower in seen:
                continue
            seen.add(rel_lower)
            discovered.append(rel)
            if len(discovered) >= 10:
                break

        return discovered

    def _append_output_file_tags(self, content: str, output_files: list[str]) -> str:
        if not output_files:
            return content

        normalized = content.strip()
        lowered = normalized.lower()
        missing = [
            path for path in output_files
            if STASH_FILE_TAG_TEMPLATE.format(path=path).lower() not in lowered
        ]
        if not missing:
            return normalized

        tags = "\n".join(f"- {STASH_FILE_TAG_TEMPLATE.format(path=path)}" for path in missing[:10])
        suffix = "Output files:\n" + tags
        if normalized:
            return normalized + "\n\n" + suffix
        return suffix

    def start_run(self, *, project_id: str, conversation_id: str, trigger_message_id: str, mode: str) -> dict[str, Any]:
        context = self.project_store.get(project_id)
        if context is None:
            raise ValueError("Unknown project")

        repo = ProjectRepository(context)
        recovered = repo.recover_orphaned_runs(active_run_ids=set(self._tasks.keys()))
        if recovered:
            logger.warning("Recovered %s orphaned run(s) before starting new run project_id=%s", recovered, project_id)
        run = repo.create_run(conversation_id, trigger_message_id, mode=mode)

        task = asyncio.create_task(
            self._execute_run(
                project_id=project_id,
                conversation_id=conversation_id,
                run_id=run["id"],
                trigger_message_id=trigger_message_id,
            )
        )
        self._tasks[run["id"]] = task
        logger.info(
            "Run started run_id=%s project_id=%s conversation_id=%s mode=%s",
            run["id"],
            project_id,
            conversation_id,
            mode,
        )
        return run

    async def cancel_run(self, *, project_id: str, run_id: str) -> dict[str, Any] | None:
        context = self.project_store.get(project_id)
        if context is None:
            return None

        repo = ProjectRepository(context)
        run = repo.get_run(run_id)
        if run is None:
            return None

        task = self._tasks.get(run_id)
        if task and not task.done():
            task.cancel()
            with context.lock:
                repo.update_run(run_id, status="cancelled", finished=True)
                repo.add_event("run_cancelled", conversation_id=run["conversation_id"], run_id=run_id, payload={"reason": "user_request"})
            return repo.get_run(run_id)

        return run

    async def _execute_run(self, *, project_id: str, conversation_id: str, run_id: str, trigger_message_id: str) -> None:
        context = self.project_store.get(project_id)
        if context is None:
            return
        repo = ProjectRepository(context)
        run_started = time.perf_counter()
        scan_ms = 0
        search_ms = 0
        planning_ms = 0
        command_exec_ms = 0
        synthesis_ms = 0

        try:
            with context.lock:
                repo.update_run(run_id, status="running")
                repo.add_event("run_started", conversation_id=conversation_id, run_id=run_id, payload={"trigger_message_id": trigger_message_id})

            trigger_msg = repo.get_message(conversation_id, trigger_message_id)
            if not trigger_msg:
                raise RuntimeError("Trigger message not found")

            history = repo.list_messages(conversation_id, cursor=None, limit=500)
            skills = load_skill_bundle(context.stash_dir)
            rag_hits: list[dict[str, Any]] = []
            try:
                scan_started = time.perf_counter()
                await asyncio.to_thread(self.indexer.scan_project_files, context, repo)
                scan_ms = int((time.perf_counter() - scan_started) * 1000)
                search_started = time.perf_counter()
                rag_hits = await asyncio.to_thread(
                    self.indexer.search,
                    repo,
                    query=str(trigger_msg.get("content", ""))[:2000],
                    limit=8,
                )
                search_ms = int((time.perf_counter() - search_started) * 1000)
            except Exception:
                logger.exception("RAG context preparation failed run_id=%s", run_id)

            planner_user_message = self._compose_planner_user_message(trigger_msg, rag_hits=rag_hits)
            planning_started = time.perf_counter()
            plan = await asyncio.to_thread(
                self.planner.plan,
                user_message=planner_user_message,
                conversation_history=history,
                skill_bundle=skills,
                project_summary=repo.project_view(),
            )
            planning_ms = int((time.perf_counter() - planning_started) * 1000)
            logger.info(
                "Planner produced run_id=%s commands=%s planning_ms=%s rag_scan_ms=%s rag_search_ms=%s rag_hits=%s",
                run_id,
                len(plan.commands),
                planning_ms,
                scan_ms,
                search_ms,
                len(rag_hits),
            )
            with context.lock:
                repo.add_event(
                    "run_planned",
                    conversation_id=conversation_id,
                    run_id=run_id,
                    payload={
                        "command_count": len(plan.commands),
                        "rag_hit_count": len(rag_hits),
                        "rag_paths": [str(hit.get("path_or_url") or "") for hit in rag_hits[:6]],
                        "planner_preview": plan.planner_text[:1200],
                        "commands": [command.cmd for command in plan.commands[:12]],
                    },
                )

            tool_summaries: list[str] = []
            tool_results_for_response: list[dict[str, Any]] = []
            output_files_for_response: list[str] = []
            output_file_seen: set[str] = set()
            failures = 0

            if plan.commands:
                for step_index, command in enumerate(plan.commands, start=1):
                    command_base_cwd = self._resolve_command_base_cwd(context=context, command_cwd=command.cwd)
                    baseline = self._capture_output_baseline(
                        context=context,
                        cwd=command_base_cwd,
                        command_text=command.cmd,
                    )
                    with context.lock:
                        step_id = repo.create_run_step(
                            run_id,
                            step_index,
                            "codex_cmd",
                            {
                                "raw": command.raw,
                                "cmd": command.cmd,
                                "cwd": command.cwd,
                                "worktree": command.worktree,
                            },
                        )
                        repo.add_event(
                            "run_step_started",
                            conversation_id=conversation_id,
                            run_id=run_id,
                            payload={"step_id": step_id, "step_index": step_index},
                        )

                    try:
                        step_exec_started = time.perf_counter()
                        result = await asyncio.to_thread(self.codex.execute, context, command)
                        step_exec_ms = int((time.perf_counter() - step_exec_started) * 1000)
                        command_exec_ms += step_exec_ms
                        stderr_excerpt = ((result.stderr or "").strip().splitlines() or [""])[0][:240]
                        stdout_excerpt = ((result.stdout or "").strip().splitlines() or [""])[0][:240]
                        failure_detail = stderr_excerpt or stdout_excerpt
                        output = {
                            "engine": result.engine,
                            "exit_code": result.exit_code,
                            "stdout": result.stdout,
                            "stderr": result.stderr,
                            "cwd": result.cwd,
                            "worktree_path": result.worktree_path,
                            "started_at": result.started_at,
                            "finished_at": result.finished_at,
                        }
                        output_files = self._detect_output_files(
                            context=context,
                            cwd=Path(result.cwd),
                            command_text=command.cmd,
                            stdout=result.stdout or "",
                            stderr=result.stderr or "",
                            baseline=baseline,
                        )
                        if output_files:
                            output["output_files"] = output_files
                        status = "completed" if result.exit_code == 0 else "failed"
                        if result.exit_code != 0:
                            failures += 1

                        with context.lock:
                            repo.finish_run_step(step_id, status=status, output_data=output)
                            event_payload: dict[str, Any] = {
                                "step_id": step_id,
                                "step_index": step_index,
                                "status": status,
                                "exit_code": result.exit_code,
                                "duration_ms": step_exec_ms,
                            }
                            if result.exit_code != 0 and failure_detail:
                                event_payload["detail"] = failure_detail
                            if output_files:
                                event_payload["output_files"] = output_files
                            repo.add_event(
                                "run_step_completed",
                                conversation_id=conversation_id,
                                run_id=run_id,
                                payload=event_payload,
                            )
                            repo.create_message(
                                conversation_id,
                                role="tool",
                                content=(
                                    f"Executed command:\n{command.cmd}\n\n"
                                    f"exit_code={result.exit_code}\n"
                                    f"stdout:\n{(result.stdout or '').strip()[:4000]}\n\n"
                                    f"stderr:\n{(result.stderr or '').strip()[:2000]}"
                                ),
                                parts=[],
                                parent_message_id=trigger_message_id,
                                metadata={"run_id": run_id, "step_index": step_index},
                            )
                        logger.info(
                            "Run step completed run_id=%s step=%s exit_code=%s duration_ms=%s cmd=%r",
                            run_id,
                            step_index,
                            result.exit_code,
                            step_exec_ms,
                            command.cmd[:200],
                        )

                        summary = f"Step {step_index}: exit_code={result.exit_code}"
                        if result.exit_code != 0 and failure_detail:
                            summary += f" ({failure_detail})"
                        tool_summaries.append(summary)
                        tool_results_for_response.append(
                            {
                                "step_index": step_index,
                                "status": status,
                                "exit_code": result.exit_code,
                                "cmd": command.cmd,
                                "stdout": result.stdout,
                                "stderr": result.stderr,
                            }
                        )
                        for artifact in output_files:
                            artifact_lower = artifact.lower()
                            if artifact_lower in output_file_seen:
                                continue
                            output_file_seen.add(artifact_lower)
                            output_files_for_response.append(artifact)

                    except (CodexCommandError, RuntimeError) as exc:
                        failures += 1
                        with context.lock:
                            repo.finish_run_step(step_id, status="failed", error=str(exc))
                            repo.add_event(
                                "run_step_completed",
                                conversation_id=conversation_id,
                                run_id=run_id,
                                payload={"step_id": step_id, "step_index": step_index, "status": "failed", "error": str(exc)},
                            )
                        tool_summaries.append(f"Step {step_index}: failed ({exc})")
                        tool_results_for_response.append(
                            {
                                "step_index": step_index,
                                "status": "failed",
                                "exit_code": 1,
                                "cmd": command.cmd,
                                "stdout": "",
                                "stderr": str(exc),
                            }
                        )
            assistant_content = self.planner.sanitize_assistant_text(plan.planner_text) or plan.planner_text
            synthesis_started = time.perf_counter()
            synthesized = self.planner.synthesize_response(
                user_message=str(trigger_msg.get("content", "")),
                planner_text=plan.planner_text,
                project_summary=repo.project_view(),
                tool_results=tool_results_for_response,
                output_files=output_files_for_response,
            )
            synthesis_ms = int((time.perf_counter() - synthesis_started) * 1000)
            if synthesized:
                assistant_content = synthesized

            assistant_content = self._append_output_file_tags(assistant_content, output_files_for_response)
            if failures and tool_summaries:
                assistant_content += "\n\nExecution summary:\n- " + "\n- ".join(tool_summaries)
            elif not assistant_content.strip() and tool_summaries:
                assistant_content = "Execution summary:\n- " + "\n- ".join(tool_summaries)

            with context.lock:
                assistant_parts: list[dict[str, Any]] = [
                    {"type": "output_file", "path": path}
                    for path in output_files_for_response[:10]
                ]
                final_message = repo.create_message(
                    conversation_id,
                    role="assistant",
                    content=assistant_content,
                    parts=assistant_parts,
                    parent_message_id=trigger_message_id,
                    metadata={"run_id": run_id},
                )
                repo.add_event(
                    "message_finalized",
                    conversation_id=conversation_id,
                    run_id=run_id,
                    payload={"message_id": final_message["id"]},
                )

                if failures:
                    repo.update_run(
                        run_id,
                        status="failed",
                        output_summary=f"{len(plan.commands)} step(s), {failures} failed",
                        error="One or more run steps failed",
                        finished=True,
                    )
                    repo.add_event(
                        "run_failed",
                        conversation_id=conversation_id,
                        run_id=run_id,
                        payload={
                            "failures": failures,
                            "latency_ms": {
                                "rag_scan": scan_ms,
                                "rag_search": search_ms,
                                "planning": planning_ms,
                                "execution": command_exec_ms,
                                "synthesis": synthesis_ms,
                            },
                        },
                    )
                else:
                    repo.update_run(
                        run_id,
                        status="done",
                        output_summary=f"{len(plan.commands)} step(s) executed",
                        finished=True,
                    )
                    repo.add_event(
                        "run_completed",
                        conversation_id=conversation_id,
                        run_id=run_id,
                        payload={
                            "steps": len(plan.commands),
                            "latency_ms": {
                                "rag_scan": scan_ms,
                                "rag_search": search_ms,
                                "planning": planning_ms,
                                "execution": command_exec_ms,
                                "synthesis": synthesis_ms,
                            },
                        },
                    )
                total_ms = int((time.perf_counter() - run_started) * 1000)
                logger.info(
                    "Run latency summary run_id=%s status=%s total_ms=%s planning_ms=%s execution_ms=%s synthesis_ms=%s rag_scan_ms=%s rag_search_ms=%s steps=%s failures=%s",
                    run_id,
                    "failed" if failures else "done",
                    total_ms,
                    planning_ms,
                    command_exec_ms,
                    synthesis_ms,
                    scan_ms,
                    search_ms,
                    len(plan.commands),
                    failures,
                )

        except asyncio.CancelledError:
            with context.lock:
                repo.update_run(run_id, status="cancelled", finished=True)
                repo.add_event(
                    "run_cancelled",
                    conversation_id=conversation_id,
                    run_id=run_id,
                    payload={"reason": "cancelled"},
                )
            raise
        except Exception as exc:
            with context.lock:
                repo.update_run(
                    run_id,
                    status="failed",
                    output_summary="Run crashed",
                    error=str(exc),
                    finished=True,
                )
                repo.add_event(
                    "run_failed",
                    conversation_id=conversation_id,
                    run_id=run_id,
                    payload={"error": str(exc)},
                )
        finally:
            self._tasks.pop(run_id, None)
