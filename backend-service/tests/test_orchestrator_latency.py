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
from stash_backend.types import DirectCommandResult, DirectExecutionResult, ExecutionResult, PlanResult


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
    def __init__(
        self,
        delays_by_command: dict[str, float] | None = None,
        direct_commands: list[DirectCommandResult] | None = None,
        direct_assistant_text: str = "Direct execution complete.",
        mutate_files: bool = False,
    ):
        self.delays_by_command = delays_by_command or {}
        self.direct_commands = direct_commands
        self.direct_assistant_text = direct_assistant_text
        self.mutate_files = mutate_files
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

        if self.mutate_files:
            cmd = command.cmd.strip()
            if cmd.startswith("touch "):
                target = cmd.removeprefix("touch ").strip().split(" ", 1)[0]
                path = context.root_path / target
                path.parent.mkdir(parents=True, exist_ok=True)
                path.touch()

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

    def execute_task(
        self,
        context: Any,
        *,
        user_message: str,
        conversation_history: list[dict[str, Any]],
        skill_bundle: str,
        project_summary: dict[str, Any],
    ) -> DirectExecutionResult:
        _ = (context, user_message, conversation_history, skill_bundle, project_summary)
        return DirectExecutionResult(
            engine="codex-cli",
            assistant_text=self.direct_assistant_text,
            commands=self.direct_commands
            or [
                DirectCommandResult(
                    command="cat notes.txt",
                    exit_code=0,
                    output="summary line 1\nsummary line 2\n",
                    status="completed",
                    cwd=str(context.root_path),
                ),
                DirectCommandResult(
                    command="python3 -c 'open(\"summary.txt\",\"w\").write(\"done\")'",
                    exit_code=0,
                    output="created: summary.txt",
                    status="completed",
                    cwd=str(context.root_path),
                ),
            ],
            started_at="2026-01-01T00:00:00Z",
            finished_at="2026-01-01T00:00:02Z",
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
                execution_mode="planner",
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
                execution_mode="planner",
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

    async def test_execute_mode_skips_planner_and_supports_multi_step(self) -> None:
        planner = _FakePlanner([])
        codex = _FakeCodex()
        runtime_store = _FakeRuntimeConfigStore(
            RuntimeConfig(
                execution_mode="execute",
                planner_mode="fast",
                planner_timeout_seconds=60,
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
        self.assertEqual(len(planner.plan_calls), 0)

        events = self.repo.list_events(after_id=0, conversation_id=self.conversation["id"], limit=400)
        started = [event for event in events if event["type"] == "run_started"]
        self.assertTrue(started)
        self.assertEqual(str(started[-1]["payload"].get("execution_mode")), "execute")

        completed_steps = [event for event in events if event["type"] == "run_step_completed"]
        self.assertEqual(len(completed_steps), 2)
        self.assertEqual(str(completed_steps[0]["payload"].get("execution_mode")), "direct_codex")

    async def test_execute_mode_read_only_does_not_emit_output_files(self) -> None:
        planner = _FakePlanner([])
        codex = _FakeCodex(
            direct_commands=[
                DirectCommandResult(
                    command="cat notes.txt",
                    exit_code=0,
                    output="hello world",
                    status="completed",
                    cwd=str(self.context.root_path),
                )
            ]
        )
        runtime_store = _FakeRuntimeConfigStore(RuntimeConfig(execution_mode="execute"))
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

        messages = self.repo.list_messages(self.conversation["id"], cursor=None, limit=200)
        assistants = [msg for msg in messages if msg.get("role") == "assistant"]
        self.assertTrue(assistants)
        self.assertEqual(assistants[-1].get("parts"), [])

    async def test_preview_changes_require_confirmation_then_apply(self) -> None:
        planner = _FakePlanner(
            [
                _plan_with_commands(
                    (
                        "Create file.\n"
                        "<codex_cmd>\nworktree: main\ncwd: .\ncmd: touch output.txt\n</codex_cmd>\n"
                    ),
                    used_backend="codex",
                )
            ],
            synthesized_text="Prepared changes.",
        )
        codex = _FakeCodex(mutate_files=True)
        runtime_store = _FakeRuntimeConfigStore(RuntimeConfig(execution_mode="planner"))
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
        self.assertEqual(run["status"], "awaiting_confirmation")
        self.assertFalse((self.context.root_path / "output.txt").exists())
        self.assertTrue(run.get("requires_confirmation"))

        applied = orchestrator.apply_run_changes(project_id=self.context.project_id, run_id=run_id)
        self.assertIsNotNone(applied)
        self.assertEqual(applied["status"], "done")
        self.assertTrue((self.context.root_path / "output.txt").exists())

    async def test_discard_preview_changes_keeps_project_unmodified(self) -> None:
        planner = _FakePlanner(
            [
                _plan_with_commands(
                    (
                        "Create file.\n"
                        "<codex_cmd>\nworktree: main\ncwd: .\ncmd: touch should_discard.txt\n</codex_cmd>\n"
                    ),
                    used_backend="codex",
                )
            ],
            synthesized_text="Prepared changes.",
        )
        codex = _FakeCodex(mutate_files=True)
        runtime_store = _FakeRuntimeConfigStore(RuntimeConfig(execution_mode="planner"))
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
        self.assertEqual(run["status"], "awaiting_confirmation")
        self.assertFalse((self.context.root_path / "should_discard.txt").exists())

        discarded = orchestrator.discard_run_changes(project_id=self.context.project_id, run_id=run_id)
        self.assertIsNotNone(discarded)
        self.assertEqual(discarded["status"], "cancelled")
        self.assertFalse((self.context.root_path / "should_discard.txt").exists())

    async def test_run_phase_events_emitted_in_order(self) -> None:
        planner = _FakePlanner(
            [
                _plan_with_commands(
                    (
                        "Do one read step.\n"
                        "<codex_cmd>\nworktree: main\ncwd: .\ncmd: ls -la\n</codex_cmd>\n"
                    ),
                    used_backend="codex",
                )
            ],
            synthesized_text="Done",
        )
        codex = _FakeCodex()
        runtime_store = _FakeRuntimeConfigStore(RuntimeConfig(execution_mode="planner"))
        orchestrator = RunOrchestrator(
            project_store=self.project_store,
            indexer=_FakeIndexer(),
            planner=planner,  # type: ignore[arg-type]
            codex=codex,  # type: ignore[arg-type]
            runtime_config_store=runtime_store,  # type: ignore[arg-type]
        )

        run_id = await self._run_orchestrator(orchestrator)
        self.assertIsNotNone(self.repo.get_run(run_id))

        events = self.repo.list_events(after_id=0, conversation_id=self.conversation["id"], limit=400)
        phases = [str(event["payload"].get("phase")) for event in events if event["type"] == "run_phase"]
        self.assertIn("preparing_context", phases)
        self.assertIn("planning", phases)
        self.assertIn("executing", phases)
        self.assertIn("synthesizing", phases)
        self.assertIn("completed", phases)
        self.assertLess(phases.index("preparing_context"), phases.index("planning"))
        self.assertLess(phases.index("planning"), phases.index("executing"))
        self.assertLess(phases.index("executing"), phases.index("synthesizing"))

    async def test_run_progress_emits_step_counts(self) -> None:
        planner = _FakePlanner(
            [
                _plan_with_commands(
                    (
                        "Read two files.\n"
                        "<codex_cmd>\nworktree: main\ncwd: .\ncmd: ls -la\n</codex_cmd>\n"
                        "<codex_cmd>\nworktree: main\ncwd: .\ncmd: pwd\n</codex_cmd>\n"
                    ),
                    used_backend="codex",
                )
            ],
            synthesized_text="Done",
        )
        codex = _FakeCodex()
        orchestrator = RunOrchestrator(
            project_store=self.project_store,
            indexer=_FakeIndexer(),
            planner=planner,  # type: ignore[arg-type]
            codex=codex,  # type: ignore[arg-type]
            runtime_config_store=_FakeRuntimeConfigStore(RuntimeConfig(execution_mode="planner")),  # type: ignore[arg-type]
        )
        await self._run_orchestrator(orchestrator)
        events = self.repo.list_events(after_id=0, conversation_id=self.conversation["id"], limit=400)
        progress_events = [event for event in events if event["type"] == "run_progress"]
        self.assertTrue(progress_events)
        totals = {int(event["payload"].get("total_steps", 0)) for event in progress_events}
        self.assertEqual(totals, {2})
        final = progress_events[-1]["payload"]
        self.assertEqual(int(final.get("completed_steps", 0)), 2)
        self.assertEqual(int(final.get("failed_steps", 0)), 0)

    async def test_minimal_run_note_emission(self) -> None:
        planner = _FakePlanner(
            [
                _plan_with_commands(
                    (
                        "One step.\n"
                        "<codex_cmd>\nworktree: main\ncwd: .\ncmd: ls -la\n</codex_cmd>\n"
                    ),
                    used_backend="codex",
                )
            ],
            synthesized_text="Done",
        )
        codex = _FakeCodex()
        orchestrator = RunOrchestrator(
            project_store=self.project_store,
            indexer=_FakeIndexer(),
            planner=planner,  # type: ignore[arg-type]
            codex=codex,  # type: ignore[arg-type]
            runtime_config_store=_FakeRuntimeConfigStore(RuntimeConfig(execution_mode="planner")),  # type: ignore[arg-type]
        )
        await self._run_orchestrator(orchestrator)

        events = self.repo.list_events(after_id=0, conversation_id=self.conversation["id"], limit=400)
        notes = [event for event in events if event["type"] == "run_note"]
        self.assertGreaterEqual(len(notes), 1)
        self.assertLessEqual(len(notes), 3)
        note_kinds = {str(event["payload"].get("kind")) for event in notes}
        self.assertIn("synthesis", note_kinds)


if __name__ == "__main__":
    unittest.main()
