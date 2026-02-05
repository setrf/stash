from __future__ import annotations

import unittest
from unittest import mock

from stash_backend.config import Settings
from stash_backend.planner import Planner


def _project_summary() -> dict[str, str]:
    return {"id": "proj_1", "name": "Demo", "root_path": "/tmp/demo-project"}


class PlannerTests(unittest.TestCase):
    def test_actionable_message_without_planners_keeps_original_fallback(self) -> None:
        planner = Planner(Settings(codex_bin="definitely-not-installed", planner_cmd=None))
        result = planner.plan(
            user_message="read my resume and create a new version in txt file with suggestions for me to be a developer",
            conversation_history=[],
            skill_bundle="",
            project_summary=_project_summary(),
        )

        self.assertEqual(result.commands, [])
        self.assertIn("Planner fallback: could not generate an execution plan.", result.planner_text)

    def test_non_actionable_message_keeps_original_fallback(self) -> None:
        planner = Planner(Settings(codex_bin="definitely-not-installed", planner_cmd=None))
        result = planner.plan(
            user_message="hello there",
            conversation_history=[],
            skill_bundle="",
            project_summary=_project_summary(),
        )

        self.assertEqual(result.commands, [])
        self.assertIn("Planner fallback: could not generate an execution plan.", result.planner_text)

    def test_openai_planner_is_preferred_over_codex(self) -> None:
        planner = Planner(
            Settings(
                codex_bin="codex",
                planner_cmd=None,
                openai_api_key="test-key",
                openai_model="gpt-5-mini",
            )
        )
        openai_text = (
            "Planning from GPT.\n"
            "<codex_cmd>\n"
            "worktree: main\n"
            "cwd: .\n"
            "cmd: echo from-openai\n"
            "</codex_cmd>"
        )
        with (
            mock.patch.object(planner, "_run_external_planner", return_value=None),
            mock.patch.object(planner, "_run_openai_planner", return_value=openai_text) as mocked_openai,
            mock.patch.object(planner, "_run_codex_planner", return_value=None) as mocked_codex,
        ):
            result = planner.plan(
                user_message="create notes.txt",
                conversation_history=[],
                skill_bundle="",
                project_summary=_project_summary(),
            )

        self.assertEqual(mocked_openai.call_count, 1)
        self.assertEqual(mocked_codex.call_count, 0)
        self.assertEqual(len(result.commands), 1)
        self.assertEqual(result.commands[0].cmd, "echo from-openai")

    def test_codex_retry_is_used_when_primary_attempt_has_no_commands(self) -> None:
        planner = Planner(Settings(codex_bin="codex", planner_cmd=None))
        primary_text = "I can help with this request."
        retry_text = (
            "Executing now.\n"
            "<codex_cmd>\n"
            "worktree: main\n"
            "cwd: .\n"
            "cmd: echo ok\n"
            "</codex_cmd>"
        )

        with (
            mock.patch.object(planner, "_run_external_planner", return_value=None),
            mock.patch.object(planner, "_run_openai_planner", return_value=None),
            mock.patch.object(planner, "_run_codex_planner", side_effect=[primary_text, retry_text]) as mocked_run,
        ):
            result = planner.plan(
                user_message="create notes.txt",
                conversation_history=[],
                skill_bundle="",
                project_summary=_project_summary(),
            )

        self.assertEqual(mocked_run.call_count, 2)
        self.assertEqual(len(result.commands), 1)
        self.assertEqual(result.commands[0].cmd, "echo ok")


if __name__ == "__main__":
    unittest.main()
