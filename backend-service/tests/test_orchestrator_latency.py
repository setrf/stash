from __future__ import annotations

import tempfile
import threading
import time
import unittest
from typing import Any

from stash_backend.codex import parse_tagged_commands
from stash_backend.db import ProjectRepository
from stash_backend.orchestrator import RunOrchestrator
from stash_backend.project_store import ProjectStore
from stash_backend.runtime_config import RuntimeConfig
from stash_backend.types import ExecutionResult, PlanResult


def _plan_with_commands(planner_text: str, **kwargs: Any) -> PlanResult:
    return PlanResult(
        planner_text=planner_text,
        commands=parse_tagged_commands(planner_text),
        **kwargs,
    )


class _FakeRuntimeConfigStore:
    def __init__(self, config: RuntimeConfig):
        self._config = config

    def get(self) -> RuntimeConfig:
        return self._config


class _FakeIndexer:
    def scan_project_files(self, _context: Any, _repo: Any) -> None:
        return None

    def search(self, _repo: Any, *, query: str, limit: int) -> list[dict[str, Any]]:
        _ = (query, limit)
        return []


class _FakePlanner:
    def __init__(self, plans: list[PlanResult], synthesized_text: str = "Completed run."):
        self._plans = list(plans)
        self.plan_calls: list[dict[str, Any]] = []
        self.synthesized_text = synthesized_text

    def plan(self, **kwargs: Any) -> PlanResult:
        self.plan_calls.append(kwargs)
        if not self._plans:
            return PlanResult(
                planner_text="Planner fallback: no test plan available",
                commands=[],
                used_backend="fallback",
                used_fallback="test_empty",
            )
        return self._plans.pop(0)

    def sanitize_assistant_text(self, text: str) -> str:
        return text

    def synthesize_response(self, **_kwargs: Any) -> str | None:
        return self.synthesized_text


class _FakeCodex:
    def __init__(self, delays_by_command: dict[str, float] | None = None):
        self.delays_by_command = delays_by_command or {}
        self.starts: dict[str, float] = {}
        self.ends: dict[str, float] = {}
        self._lock = threading.Lock()

    def execute(self, context: Any, command: Any) -> ExecutionResult:
        now = time.monotonic()
        with self._lock:
            self.starts[command.cmd] = now

        delay = float(self.delays_by_command.get(command.cmd, 0.01))
        if delay > 0:
            time.sleep(delay)

        finished = time.monotonic()
        with self._lock:
            self.ends[command.cmd] = finished

        return ExecutionResult(
            engine="shell",
            exit_code=0,
            stdout=f"ok: {command.cmd}",
            stderr="",
            started_at="2026-01-01T00:00:00Z",
            finished_at="2026-01-01T00:00:01Z",
            cwd=str(context.root_path),
            worktree_path=str(context.stash_dir / "worktrees" / "main"),
        )


class OrchestratorLatencyTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.project_store = ProjectStore()
        self.context = self.project_store.open_or_create(name="Demo", root_path=self._tmp.name)
        self.repo = ProjectRepository(self.context)
        self.conversation = self.repo.create_conversation("General")
        self.message = self.repo.create_message(
            self.conversation["id"],
            role="user",
            content="Please summarize notes.txt",
            parts=[],
            parent_message_id=None,
            metadata={},
        )

    def tearDown(self) -> None:
        self.project_store.close()
        self._tmp.cleanup()

    async def _run_orchestrator(self, orchestrator: RunOrchestrator) -> str:
        run = orchestrator.start_run(
            project_id=self.context.project_id,
            conversation_id=self.conversation["id"],
            trigger_message_id=self.message["id"],
            mode="manual",
        )
        run_id = str(run["id"])
        task = orchestrator._tasks[run_id]
        await task
        return run_id

    async def test_planner_timeout_emits_delayed_event_and_continues(self) -> None:
        first_plan = PlanResult(
            planner_text="Planner fallback: could not generate an execution plan. Try again or rephrase the request.",
            commands=[],
            timed_out_primary=True,
            used_backend="fallback",
            used_fallback="planner_unavailable",
        )
        second_plan = _plan_with_commands(
            (
                "Will execute after delayed planning.\n"
                "<codex_cmd>\n"
                "worktree: main\n"
                "cwd: .\n"
                "cmd: ls -la\n"
                "</codex_cmd>"
            ),
            used_backend="codex",
        )
        planner = _FakePlanner([first_plan, second_plan], synthesized_text="Summary done.")
        codex = _FakeCodex()
        runtime_store = _FakeRuntimeConfigStore(
            RuntimeConfig(
                planner_mode="fast",
                planner_timeout_seconds=60,
                execution_parallel_reads_enabled=True,
                execution_parallel_reads_max_workers=3,
            )
        )
        orchestrator = RunOrchestrator(
            project_store=self.project_store,
            indexer=_FakeIndexer(),
            planner=planner,  # type: ignore[arg-type]
            codex=codex,  # type: ignore[arg-type]
            runtime_config_store=runtime_store,  # type: ignore[arg-type]
        )

        run_id = await self._run_orchestrator(orchestrator)
        run = self.repo.get_run(run_id)
        self.assertIsNotNone(run)
        self.assertEqual(run["status"], "done")
        self.assertEqual(len(planner.plan_calls), 2)

        events = self.repo.list_events(after_id=0, conversation_id=self.conversation["id"], limit=400)
        event_types = [event["type"] for event in events]
        self.assertIn("run_planning_delayed", event_types)
        self.assertIn("run_completed", event_types)
        self.assertIn("run_latency_summary", event_types)

    async def test_parallel_read_batch_runs_before_sequential_write(self) -> None:
        planner = _FakePlanner(
            [
                _plan_with_commands(
                    (
                        "Plan with read and write steps.\n"
                        "<codex_cmd>\nworktree: main\ncwd: .\ncmd: cat notes.txt\n</codex_cmd>\n"
                        "<codex_cmd>\nworktree: main\ncwd: .\ncmd: ls -la\n</codex_cmd>\n"
                        "<codex_cmd>\nworktree: main\ncwd: .\ncmd: pwd\n</codex_cmd>\n"
                        "<codex_cmd>\nworktree: main\ncwd: .\ncmd: touch result.txt\n</codex_cmd>\n"
                    ),
                    used_backend="codex",
                )
            ],
            synthesized_text="Done",
        )
        codex = _FakeCodex(
            delays_by_command={
                "cat notes.txt": 0.18,
                "ls -la": 0.18,
                "pwd": 0.18,
                "touch result.txt": 0.02,
            }
        )
        runtime_store = _FakeRuntimeConfigStore(
            RuntimeConfig(
                planner_mode="fast",
                planner_timeout_seconds=60,
                execution_parallel_reads_enabled=True,
                execution_parallel_reads_max_workers=3,
            )
        )
        orchestrator = RunOrchestrator(
            project_store=self.project_store,
            indexer=_FakeIndexer(),
            planner=planner,  # type: ignore[arg-type]
            codex=codex,  # type: ignore[arg-type]
            runtime_config_store=runtime_store,  # type: ignore[arg-type]
        )

        run_id = await self._run_orchestrator(orchestrator)
        run = self.repo.get_run(run_id)
        self.assertIsNotNone(run)
        self.assertEqual(run["status"], "done")

        read_commands = ["cat notes.txt", "ls -la", "pwd"]
        write_command = "touch result.txt"
        read_end_max = max(codex.ends[cmd] for cmd in read_commands)
        self.assertGreaterEqual(codex.starts[write_command], read_end_max)

        events = self.repo.list_events(after_id=0, conversation_id=self.conversation["id"], limit=400)
        completed_events = [event for event in events if event["type"] == "run_step_completed"]
        modes_by_step = {
            int(event["payload"].get("step_index", 0)): str(event["payload"].get("execution_mode", ""))
            for event in completed_events
        }
        self.assertEqual(modes_by_step.get(1), "parallel_read")
        self.assertEqual(modes_by_step.get(2), "parallel_read")
        self.assertEqual(modes_by_step.get(3), "parallel_read")
        self.assertEqual(modes_by_step.get(4), "sequential")


if __name__ == "__main__":
    unittest.main()
