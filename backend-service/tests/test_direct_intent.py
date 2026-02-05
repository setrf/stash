from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from stash_backend.direct_intent import build_direct_commands


class DirectIntentTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "notes.txt").write_text("hello", encoding="utf-8")
        (self.root / "README.md").write_text("# title", encoding="utf-8")
        (self.root / "data.csv").write_text("name,score\nA,10\n", encoding="utf-8")
        (self.root / "resume.pdf").write_bytes(b"%PDF-1.4\n%mock")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def test_read_txt_returns_safe_command(self) -> None:
        commands = build_direct_commands(
            user_message="read notes.txt",
            parts=[],
            project_root=self.root,
        )
        self.assertEqual(len(commands), 1)
        self.assertIn("sed -n '1,220p' notes.txt", commands[0].cmd)

    def test_summarize_md_to_txt_file_creates_write_command(self) -> None:
        commands = build_direct_commands(
            user_message="summarize README.md and create README_summary.txt",
            parts=[],
            project_root=self.root,
        )
        self.assertEqual(len(commands), 1)
        self.assertIn("python3 -c", commands[0].cmd)
        self.assertIn("README_summary.txt", commands[0].cmd)

    def test_summarize_csv_uses_csv_script(self) -> None:
        commands = build_direct_commands(
            user_message="summarize data.csv",
            parts=[],
            project_root=self.root,
        )
        self.assertEqual(len(commands), 1)
        self.assertIn("import csv", commands[0].cmd)

    def test_pdf_summary_to_output_file(self) -> None:
        commands = build_direct_commands(
            user_message="summarize resume.pdf and save as resume_summary.txt",
            parts=[],
            project_root=self.root,
        )
        self.assertEqual(len(commands), 1)
        self.assertIn("PdfReader", commands[0].cmd)
        self.assertIn("resume_summary.txt", commands[0].cmd)


if __name__ == "__main__":
    unittest.main()
