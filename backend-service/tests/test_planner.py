from __future__ import annotations

import subprocess
import unittest
from unittest import mock

from stash_backend.config import Settings
from stash_backend.planner import Planner
from stash_backend.runtime_config import RuntimeConfig
from stash_backend.types import TaggedCommand


def _project_summary() -> dict[str, str]:
    return {"id": "proj_1", "name": "Demo", "root_path": "/tmp/demo-project"}


class PlannerTests(unittest.TestCase):
    def test_runtime_config_defaults_to_gpt_5_3_codex(self) -> None:
        runtime = RuntimeConfig.from_settings(Settings())
        self.assertEqual(runtime.codex_planner_model, "gpt-5.3-codex")

    def test_planner_prompt_uses_output_strategy_not_forced_file_creation(self) -> None:
        planner = Planner(Settings(codex_bin="codex", planner_cmd=None))
        prompt = planner._build_planner_prompt(
            user_message="explain what this function does",
            conversation_history=[],
            skill_bundle="",
            project_summary=_project_summary(),
            max_history_items=5,
            max_history_content_chars=300,
            max_skills_chars=1000,
            require_commands=False,
        )

        self.assertIn("Output strategy: decide whether output should be inline chat text or a project file.", prompt)
        self.assertIn("Prefer inline chat output for quick questions", prompt)
        self.assertNotIn("generate a real output file", prompt)

    def test_planner_prompt_mentions_format_selection_for_artifacts(self) -> None:
        planner = Planner(Settings(codex_bin="codex", planner_cmd=None))
        prompt = planner._build_planner_prompt(
            user_message="create a spreadsheet of expenses and save it",
            conversation_history=[],
            skill_bundle="",
            project_summary=_project_summary(),
            max_history_items=5,
            max_history_content_chars=300,
            max_skills_chars=1000,
            require_commands=True,
        )

        self.assertIn("pick the best format for the task", prompt)
        self.assertIn(".csv/.xlsx", prompt)
        self.assertIn("If you create files, include each file path", prompt)

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
        self.assertEqual(result.used_backend, "fallback")

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
        self.assertEqual(result.used_backend, "fallback")

    def test_openai_planner_is_used_when_configured_as_primary_backend(self) -> None:
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
            mock.patch.object(
                planner,
                "_runtime_config",
                return_value=RuntimeConfig(planner_backend="openai_api", openai_api_key="test-key"),
            ),
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

    def test_codex_planner_is_preferred_in_auto_mode(self) -> None:
        planner = Planner(Settings(codex_bin="codex", planner_cmd=None))
        codex_text = (
            "Planning from codex.\n"
            "<codex_cmd>\n"
            "worktree: main\n"
            "cwd: .\n"
            "cmd: echo from-codex\n"
            "</codex_cmd>"
        )
        with (
            mock.patch.object(planner, "_run_external_planner", return_value=None),
            mock.patch.object(planner, "_run_codex_planner", return_value=(codex_text, False)) as mocked_codex,
            mock.patch.object(planner, "_run_openai_planner", return_value=None) as mocked_openai,
        ):
            result = planner.plan(
                user_message="create notes.txt",
                conversation_history=[],
                skill_bundle="",
                project_summary=_project_summary(),
            )

        self.assertEqual(mocked_codex.call_count, 1)
        self.assertEqual(mocked_openai.call_count, 0)
        self.assertEqual(len(result.commands), 1)
        self.assertEqual(result.commands[0].cmd, "echo from-codex")
        self.assertEqual(result.used_backend, "codex")

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
            mock.patch.object(planner, "_run_codex_planner", side_effect=[(primary_text, False), (retry_text, False)]) as mocked_run,
        ):
            result = planner.plan(
                user_message="create notes.txt",
                conversation_history=[],
                skill_bundle="",
                project_summary=_project_summary(),
                allow_retry=True,
            )

        self.assertEqual(mocked_run.call_count, 2)
        self.assertEqual(len(result.commands), 1)
        self.assertEqual(result.commands[0].cmd, "echo ok")
        self.assertEqual(result.used_fallback, "codex_retry")

    def test_fast_mode_does_not_retry_when_primary_attempt_has_no_commands(self) -> None:
        planner = Planner(Settings(codex_bin="codex", planner_cmd=None))
        with (
            mock.patch.object(planner, "_run_external_planner", return_value=None),
            mock.patch.object(planner, "_run_openai_planner", return_value=None),
            mock.patch.object(planner, "_run_codex_planner", return_value=("No commands", False)) as mocked_run,
        ):
            result = planner.plan(
                user_message="create notes.txt",
                conversation_history=[],
                skill_bundle="",
                project_summary=_project_summary(),
            )

        self.assertEqual(mocked_run.call_count, 1)
        self.assertEqual(result.used_backend, "fallback")

    def test_heuristic_read_plan_keeps_absolute_path(self) -> None:
        planner = Planner(Settings(codex_bin="definitely-not-installed", planner_cmd=None))
        result = planner._heuristic_read_plan(
            user_message="read /Users/demo/Documents/resume.md and summarize it",
            project_summary=_project_summary(),
        )

        self.assertIsNotNone(result)
        self.assertEqual(len(result.commands), 1)
        self.assertIn("cat /Users/demo/Documents/resume.md", result.commands[0].cmd)
        self.assertEqual(result.used_fallback, "heuristic_read")

    def test_heuristic_read_plan_rewrites_pdf_to_pypdf_extraction(self) -> None:
        planner = Planner(Settings(codex_bin="definitely-not-installed", planner_cmd=None))
        result = planner._heuristic_read_plan(
            user_message="summarize /Users/demo/Documents/PepeResume.pdf",
            project_summary=_project_summary(),
        )

        self.assertIsNotNone(result)
        self.assertEqual(len(result.commands), 1)
        self.assertIn("python3 -c", result.commands[0].cmd)
        self.assertIn("PdfReader", result.commands[0].cmd)
        self.assertNotIn("cat /Users/demo/Documents/PepeResume.pdf", result.commands[0].cmd)

    def test_codex_plan_rewrites_cat_pdf_command(self) -> None:
        planner = Planner(Settings(codex_bin="codex", planner_cmd=None))
        codex_text = (
            "Plan.\n"
            "<codex_cmd>\n"
            "worktree: main\n"
            "cwd: .\n"
            "cmd: cat PepeResume.pdf\n"
            "</codex_cmd>"
        )
        with (
            mock.patch.object(planner, "_run_external_planner", return_value=None),
            mock.patch.object(planner, "_run_codex_planner", return_value=(codex_text, False)),
            mock.patch.object(planner, "_run_openai_planner", return_value=None),
        ):
            result = planner.plan(
                user_message="summarize PepeResume.pdf",
                conversation_history=[],
                skill_bundle="",
                project_summary=_project_summary(),
            )

        self.assertEqual(len(result.commands), 1)
        self.assertIn("python3 -c", result.commands[0].cmd)
        self.assertIn("PdfReader", result.commands[0].cmd)

    def test_rewrite_pdf_read_commands_keeps_text_file_commands_intact(self) -> None:
        planner = Planner(Settings(codex_bin="codex", planner_cmd=None))

        original = [
            TaggedCommand(raw="", cmd="cat notes.txt", worktree="main", cwd="."),
            TaggedCommand(raw="", cmd="cat README.md", worktree="main", cwd="."),
            TaggedCommand(raw="", cmd="cat data.csv", worktree="main", cwd="."),
        ]
        rewritten = planner._rewrite_pdf_read_commands(original)
        self.assertEqual([item.cmd for item in rewritten], [item.cmd for item in original])

    def test_codex_plan_keeps_cat_for_csv_txt_md(self) -> None:
        planner = Planner(Settings(codex_bin="codex", planner_cmd=None))
        codex_text = (
            "Plan.\n"
            "<codex_cmd>\nworktree: main\ncwd: .\ncmd: cat notes.txt\n</codex_cmd>\n"
            "<codex_cmd>\nworktree: main\ncwd: .\ncmd: cat README.md\n</codex_cmd>\n"
            "<codex_cmd>\nworktree: main\ncwd: .\ncmd: cat data.csv\n</codex_cmd>\n"
        )
        with (
            mock.patch.object(planner, "_run_external_planner", return_value=None),
            mock.patch.object(planner, "_run_codex_planner", return_value=(codex_text, False)),
            mock.patch.object(planner, "_run_openai_planner", return_value=None),
        ):
            result = planner.plan(
                user_message="read notes.txt README.md and data.csv",
                conversation_history=[],
                skill_bundle="",
                project_summary=_project_summary(),
            )

        self.assertEqual(len(result.commands), 3)
        self.assertEqual(result.commands[0].cmd, "cat notes.txt")
        self.assertEqual(result.commands[1].cmd, "cat README.md")
        self.assertEqual(result.commands[2].cmd, "cat data.csv")

    def test_codex_planner_sets_medium_reasoning_effort(self) -> None:
        planner = Planner(Settings(codex_bin="codex", planner_cmd=None))
        proc = subprocess.CompletedProcess(
            args=["codex", "exec"],
            returncode=0,
            stdout='{"type":"item.completed","item":{"type":"agent_message","text":"ok"}}\n',
            stderr="",
        )
        with (
            mock.patch.object(planner, "_codex_available", return_value=True),
            mock.patch("stash_backend.planner.resolve_binary", return_value="/usr/bin/codex"),
            mock.patch("stash_backend.planner.subprocess.run", return_value=proc) as mocked_run,
        ):
            planner._run_codex_planner(
                user_message="read notes.txt",
                conversation_history=[],
                skill_bundle="",
                project_summary=_project_summary(),
                runtime=RuntimeConfig(codex_bin="codex", codex_planner_model="gpt-5.3-codex"),
            )

        called_cmdline = mocked_run.call_args.args[0]
        self.assertIn('-c', called_cmdline)
        self.assertIn('reasoning.effort="medium"', called_cmdline)


if __name__ == "__main__":
    unittest.main()
