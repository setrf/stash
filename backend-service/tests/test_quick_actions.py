from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from typing import Any

from stash_backend.db import ProjectRepository
from stash_backend.project_store import ProjectStore
from stash_backend.quick_actions import QuickActionService


class _FakePlanner:
    def __init__(self, response_text: str | None):
        self.response_text = response_text
        self.calls = 0
        self.last_timeout: int | None = None
        self.last_prompt: str | None = None

    def classify_quick_actions(self, *, prompt: str, timeout_seconds: int = 12) -> str | None:
        self.calls += 1
        self.last_timeout = timeout_seconds
        self.last_prompt = prompt
        return self.response_text


class QuickActionServiceTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.project_store = ProjectStore()
        self.context = self.project_store.open_or_create(name="QA", root_path=self._tmp.name)
        self.repo = ProjectRepository(self.context)

    def tearDown(self) -> None:
        self.project_store.close()
        self._tmp.cleanup()

    def _write_and_snapshot(self, rel_path: str, text: str) -> Path:
        file_path = self.context.root_path / rel_path
        file_path.parent.mkdir(parents=True, exist_ok=True)
        file_path.write_text(text, encoding="utf-8")
        stat = file_path.stat()
        self.repo.upsert_file_snapshot(
            rel_path=rel_path,
            modified_time=float(stat.st_mtime),
            size_bytes=int(stat.st_size),
        )
        return file_path

    def test_ai_json_returns_two_domain_plus_general(self) -> None:
        self._write_and_snapshot("contracts/master-agreement.md", "Service agreement and termination terms.")
        self._write_and_snapshot("finance/tax_receipts.csv", "receipt,tax,amount")
        planner = _FakePlanner(
            '{"domains":['
            '{"category":"legal","confidence":0.92,"reason":"contract language"},'
            '{"category":"accounting_hr_tax","confidence":0.84,"reason":"receipt and tax docs"}'
            "]}"
        )
        service = QuickActionService(planner=planner)  # type: ignore[arg-type]

        payload = service.suggest(context=self.context, repo=self.repo, limit=3)

        categories = [item["category"] for item in payload["actions"]]
        self.assertEqual(payload["source"], "indexed_ai")
        self.assertEqual(len(payload["actions"]), 3)
        self.assertEqual(categories, ["legal", "accounting_hr_tax", "general"])

    def test_ai_malformed_falls_back_to_deterministic(self) -> None:
        self._write_and_snapshot("legal/nda_contract.txt", "NDA clause and policy obligations.")
        self._write_and_snapshot("personal/budget_plan.md", "monthly budget savings debt tracker")
        planner = _FakePlanner("not-json")
        service = QuickActionService(planner=planner)  # type: ignore[arg-type]

        payload = service.suggest(context=self.context, repo=self.repo, limit=3)

        categories = [item["category"] for item in payload["actions"]]
        self.assertEqual(payload["source"], "indexed_fallback")
        self.assertEqual(len(payload["actions"]), 3)
        self.assertIn("legal", categories)
        self.assertIn("general", categories)

    def test_no_indexed_files_returns_three_general_actions(self) -> None:
        planner = _FakePlanner('{"domains":[{"category":"legal","confidence":0.9,"reason":"unused"}]}')
        service = QuickActionService(planner=planner)  # type: ignore[arg-type]

        payload = service.suggest(context=self.context, repo=self.repo, limit=3)

        self.assertEqual(payload["source"], "general_only")
        self.assertEqual(payload["indexed_file_count"], 0)
        self.assertEqual(len(payload["actions"]), 3)
        self.assertTrue(all(item["category"] == "general" for item in payload["actions"]))
        self.assertEqual(planner.calls, 0)

    def test_mixed_domains_selects_top_two_confidence(self) -> None:
        self._write_and_snapshot("notes/context.txt", "placeholder")
        planner = _FakePlanner(
            '{"domains":['
            '{"category":"legal","confidence":0.40,"reason":"some contracts"},'
            '{"category":"markets_finance","confidence":0.93,"reason":"portfolio reports"},'
            '{"category":"accounting_hr_tax","confidence":0.78,"reason":"receipt files"}'
            "]}"
        )
        service = QuickActionService(planner=planner)  # type: ignore[arg-type]

        payload = service.suggest(context=self.context, repo=self.repo, limit=3)

        categories = [item["category"] for item in payload["actions"]]
        self.assertEqual(categories, ["markets_finance", "accounting_hr_tax", "general"])

    def test_actions_always_three_with_valid_shape(self) -> None:
        self._write_and_snapshot("misc/readme.txt", "just generic content")
        planner = _FakePlanner(None)
        service = QuickActionService(planner=planner)  # type: ignore[arg-type]

        payload = service.suggest(context=self.context, repo=self.repo, limit=3)

        actions: list[dict[str, Any]] = payload["actions"]
        self.assertEqual(len(actions), 3)
        for item in actions:
            self.assertIn("id", item)
            self.assertIn("label", item)
            self.assertIn("prompt", item)
            self.assertIn("category", item)
            self.assertIn("confidence", item)
            self.assertIn("reason", item)
            self.assertGreaterEqual(float(item["confidence"]), 0.0)
            self.assertLessEqual(float(item["confidence"]), 1.0)


if __name__ == "__main__":
    unittest.main()
