from __future__ import annotations

import sqlite3
import tempfile
import unittest
from pathlib import Path

from stash_backend.codex import CodexCommandError, CodexExecutor
from stash_backend.config import Settings
from stash_backend.planner import Planner
from stash_backend.types import ProjectContext, TaggedCommand


class CodexExecutorCwdTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        self.stash_dir = self.root / ".stash"
        (self.stash_dir / "worktrees").mkdir(parents=True, exist_ok=True)
        self.conn = sqlite3.connect(":memory:")
        self.context = ProjectContext(
            project_id="proj_1",
            name="Demo",
            root_path=self.root,
            stash_dir=self.stash_dir,
            db_path=self.stash_dir / "stash.db",
            conn=self.conn,
        )
        self.executor = CodexExecutor(Settings())
        self.worktree = self.executor._resolve_worktree(self.context, "main")

    def tearDown(self) -> None:
        self.conn.close()
        self._tmp.cleanup()

    def test_relative_dot_cwd_resolves_to_project_root(self) -> None:
        command = TaggedCommand(raw="", cmd="pwd", worktree="main", cwd=".")
        resolved = self.executor._resolve_cwd(self.context, command, self.worktree)
        self.assertEqual(resolved, self.root.resolve())

    def test_relative_subdirectory_is_project_relative(self) -> None:
        docs = self.root / "docs"
        docs.mkdir()
        command = TaggedCommand(raw="", cmd="pwd", worktree="main", cwd="docs")
        resolved = self.executor._resolve_cwd(self.context, command, self.worktree)
        self.assertEqual(resolved, docs.resolve())

    def test_escape_outside_project_is_blocked(self) -> None:
        command = TaggedCommand(raw="", cmd="pwd", worktree="main", cwd="../../..")
        with self.assertRaises(CodexCommandError):
            self.executor._resolve_cwd(self.context, command, self.worktree)


class PlannerSynthesisFallbackTests(unittest.TestCase):
    def test_local_synthesis_prefers_requested_file_output(self) -> None:
        planner = Planner(Settings(codex_bin="definitely-not-installed"))
        result = planner.synthesize_response(
            user_message="summarize PepeResume.pdf",
            planner_text="",
            project_summary={"root_path": "/tmp/demo"},
            tool_results=[
                {
                    "step_index": 1,
                    "status": "completed",
                    "exit_code": 0,
                    "cmd": "cat STASH_HISTORY.md",
                    "stdout": "history line one history line two",
                    "stderr": "",
                },
                {
                    "step_index": 2,
                    "status": "completed",
                    "exit_code": 0,
                    "cmd": "cat PepeResume_extracted.txt",
                    "stdout": (
                        "Pepe Alonso is a software engineer candidate with experience building "
                        "automation tools and backend services for developer workflows."
                    ),
                    "stderr": "",
                },
            ],
        )

        self.assertIsNotNone(result)
        self.assertIn("Summary based on the extracted output:", result or "")
        self.assertIn("software engineer candidate", result or "")
        self.assertNotIn("history line one", result or "")

    def test_local_synthesis_reports_failure_when_no_success_output(self) -> None:
        planner = Planner(Settings(codex_bin="definitely-not-installed"))
        result = planner.synthesize_response(
            user_message="read missing.txt",
            planner_text="",
            project_summary={"root_path": "/tmp/demo"},
            tool_results=[
                {
                    "step_index": 1,
                    "status": "failed",
                    "exit_code": 1,
                    "cmd": "cat missing.txt",
                    "stdout": "",
                    "stderr": "cat: missing.txt: No such file or directory",
                }
            ],
        )

        self.assertIsNotNone(result)
        self.assertIn("could not produce readable output", result or "")
        self.assertIn("No such file or directory", result or "")

    def test_synthesis_appends_output_file_tags(self) -> None:
        planner = Planner(Settings(codex_bin="definitely-not-installed"))
        result = planner.synthesize_response(
            user_message="create a summary file",
            planner_text="",
            project_summary={"root_path": "/tmp/demo"},
            tool_results=[
                {
                    "step_index": 1,
                    "status": "completed",
                    "exit_code": 0,
                    "cmd": "cat notes.txt",
                    "stdout": "Summary content line one.\nSummary content line two.",
                    "stderr": "",
                }
            ],
            output_files=["resume_summary.txt", "artifacts/report.csv"],
        )

        self.assertIsNotNone(result)
        self.assertIn("<stash_file>resume_summary.txt</stash_file>", result or "")
        self.assertIn("<stash_file>artifacts/report.csv</stash_file>", result or "")


if __name__ == "__main__":
    unittest.main()
