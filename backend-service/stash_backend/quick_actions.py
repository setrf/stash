from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .db import ProjectRepository
from .planner import Planner
from .types import ProjectContext
from .utils import utc_now_iso


@dataclass(frozen=True)
class DomainActionTemplate:
    category: str
    label: str
    prompt: str
    keywords: tuple[str, ...]


DOMAIN_ACTIONS: tuple[DomainActionTemplate, ...] = (
    DomainActionTemplate(
        category="legal",
        label="Review Legal Docs",
        prompt=(
            "Review the legal documents in this project, summarize obligations, deadlines, "
            "termination clauses, and key risks in a concise memo."
        ),
        keywords=("contract", "agreement", "nda", "msa", "sow", "terms", "policy", "clause", "lease"),
    ),
    DomainActionTemplate(
        category="accounting_hr_tax",
        label="Organize Accounting",
        prompt=(
            "Categorize receipts, tax, and payroll documents, summarize totals and missing items, "
            "and produce a clean month-by-month accounting summary."
        ),
        keywords=("receipt", "invoice", "tax", "w2", "1099", "payroll", "reimbursement", "expense", "benefits"),
    ),
    DomainActionTemplate(
        category="markets_finance",
        label="Analyze Markets",
        prompt=(
            "Analyze stock and portfolio documents, summarize positions, major risks, "
            "upcoming earnings/events, and recommended follow-up checks."
        ),
        keywords=("stock", "ticker", "portfolio", "trade", "earnings", "10-k", "10q", "balance-sheet"),
    ),
    DomainActionTemplate(
        category="personal_budget",
        label="Plan Budget",
        prompt=(
            "Build or update a personal budget plan from these docs, including spending categories, "
            "savings targets, and debt payoff priorities."
        ),
        keywords=("budget", "spending", "savings", "debt", "loan", "credit-card", "net-worth"),
    ),
)

DOMAIN_BY_CATEGORY = {item.category: item for item in DOMAIN_ACTIONS}

GENERAL_ACTIONS: tuple[dict[str, str], ...] = (
    {
        "id": "qa-general-1",
        "label": "Summarize Project Docs",
        "prompt": "Summarize the most important documents in this project and propose a prioritized action plan.",
        "reason": "General project triage.",
    },
    {
        "id": "qa-general-2",
        "label": "Find Key Deadlines",
        "prompt": "Scan project files for deadlines, due dates, and upcoming actions, then output a prioritized checklist.",
        "reason": "General deadline extraction.",
    },
    {
        "id": "qa-general-3",
        "label": "Create Action Plan",
        "prompt": "Create a practical next-step plan based on these files, including quick wins and high-risk follow-ups.",
        "reason": "General next-step planning.",
    },
)

JSON_CODE_FENCE_RE = re.compile(r"^```(?:json)?\s*|\s*```$", re.IGNORECASE)
WHITESPACE_RE = re.compile(r"\s+")
DOMAIN_THRESHOLD = 0.35


class QuickActionService:
    def __init__(self, planner: Planner):
        self.planner = planner

    def suggest(self, *, context: ProjectContext, repo: ProjectRepository, limit: int = 3) -> dict[str, Any]:
        safe_limit = max(1, min(int(limit), 6))
        evidence, indexed_file_count = self._collect_indexed_evidence(context=context, repo=repo)
        if indexed_file_count == 0:
            return self._response(
                project_id=context.project_id,
                source="general_only",
                indexed_file_count=0,
                actions=self._general_actions(limit=safe_limit),
            )

        domain_scores = self._classify_with_ai(evidence=evidence)
        source = "indexed_ai"
        if domain_scores is None:
            domain_scores = self._score_deterministic(evidence=evidence)
            source = "indexed_fallback"

        actions = self._compose_actions(domain_scores=domain_scores, limit=safe_limit)
        return self._response(
            project_id=context.project_id,
            source=source,
            indexed_file_count=indexed_file_count,
            actions=actions,
        )

    def _response(
        self,
        *,
        project_id: str,
        source: str,
        indexed_file_count: int,
        actions: list[dict[str, Any]],
    ) -> dict[str, Any]:
        return {
            "project_id": project_id,
            "actions": actions,
            "source": source,
            "indexed_file_count": indexed_file_count,
            "generated_at": utc_now_iso(),
        }

    def _collect_indexed_evidence(
        self,
        *,
        context: ProjectContext,
        repo: ProjectRepository,
        max_files: int = 18,
        max_preview_chars: int = 700,
    ) -> tuple[list[dict[str, str]], int]:
        snapshots = repo.list_file_snapshots()
        sorted_snapshots = sorted(
            snapshots,
            key=lambda item: str(item.get("last_indexed_at") or ""),
            reverse=True,
        )
        evidence: list[dict[str, str]] = []
        indexed_file_count = 0

        for snapshot in sorted_snapshots:
            rel_path = str(snapshot.get("path") or "").strip()
            if not rel_path:
                continue
            file_path = context.root_path / rel_path
            if not file_path.exists() or not file_path.is_file():
                continue
            indexed_file_count += 1
            if len(evidence) >= max_files:
                continue
            preview = self._read_preview(path=file_path, max_preview_chars=max_preview_chars)
            evidence.append({"path": rel_path, "preview": preview})
        return evidence, indexed_file_count

    def _read_preview(self, *, path: Path, max_preview_chars: int) -> str:
        try:
            data = path.read_bytes()[:24000]
        except OSError:
            return ""
        if not data or b"\x00" in data:
            return ""
        text = data.decode("utf-8", errors="ignore")
        compact = WHITESPACE_RE.sub(" ", text).strip()
        if len(compact) > max_preview_chars:
            return compact[:max_preview_chars] + "..."
        return compact

    def _classify_with_ai(self, *, evidence: list[dict[str, str]]) -> dict[str, tuple[float, str]] | None:
        prompt = self._build_ai_prompt(evidence=evidence)
        raw = self.planner.classify_quick_actions(prompt=prompt, timeout_seconds=12)
        if not raw:
            return None
        return self._parse_ai_output(raw)

    def _build_ai_prompt(self, *, evidence: list[dict[str, str]]) -> str:
        payload = [{"path": item["path"], "preview": item["preview"][:500]} for item in evidence[:18]]
        return (
            "You classify project document domains for quick assistant actions.\n"
            "Return JSON only. Do not include markdown, prose, or code fences.\n\n"
            "Allowed categories:\n"
            "- legal\n"
            "- accounting_hr_tax\n"
            "- markets_finance\n"
            "- personal_budget\n\n"
            "Rules:\n"
            "- Return a JSON object with key 'domains'.\n"
            "- domains must be a list with entries: category, confidence (0..1), reason.\n"
            "- Include only categories supported by evidence.\n"
            "- Keep reasons concise (max 120 chars).\n"
            "- If uncertain, return lower confidence.\n\n"
            "Expected JSON shape:\n"
            '{"domains":[{"category":"legal","confidence":0.82,"reason":"Contract-heavy docs"}]}\n\n'
            f"Evidence JSON:\n{json.dumps(payload, ensure_ascii=True)}\n"
        )

    def _parse_ai_output(self, raw: str) -> dict[str, tuple[float, str]] | None:
        cleaned = raw.strip()
        if cleaned.startswith("```"):
            cleaned = JSON_CODE_FENCE_RE.sub("", cleaned).strip()
        start = cleaned.find("{")
        end = cleaned.rfind("}")
        if start == -1 or end == -1 or end <= start:
            return None
        json_body = cleaned[start : end + 1]
        try:
            payload = json.loads(json_body)
        except json.JSONDecodeError:
            return None
        domains = payload.get("domains") if isinstance(payload, dict) else None
        if not isinstance(domains, list):
            return None

        parsed: dict[str, tuple[float, str]] = {}
        for item in domains:
            if not isinstance(item, dict):
                continue
            category = str(item.get("category") or "").strip()
            if category not in DOMAIN_BY_CATEGORY:
                continue
            try:
                confidence = float(item.get("confidence", 0.0))
            except (TypeError, ValueError):
                continue
            confidence = max(0.0, min(confidence, 1.0))
            reason = str(item.get("reason") or "").strip()[:180]
            existing = parsed.get(category)
            if existing is None or confidence > existing[0]:
                parsed[category] = (confidence, reason or f"AI classified as {category}.")
        return parsed or None

    def _score_deterministic(self, *, evidence: list[dict[str, str]]) -> dict[str, tuple[float, str]]:
        scored: dict[str, tuple[float, str]] = {}
        for definition in DOMAIN_ACTIONS:
            raw_score = 0.0
            matched: set[str] = set()
            for item in evidence:
                path_text = item["path"].lower()
                content_text = (item["preview"] or "").lower()
                normalized_path = path_text.replace("_", " ").replace("-", " ")
                normalized_content = content_text.replace("_", " ").replace("-", " ")
                for keyword in definition.keywords:
                    keyword_lower = keyword.lower()
                    keyword_spaced = keyword_lower.replace("-", " ")
                    path_hit = keyword_lower in path_text or keyword_spaced in normalized_path
                    content_hit = keyword_lower in content_text or keyword_spaced in normalized_content
                    if path_hit:
                        raw_score += 1.35
                        matched.add(keyword)
                    if content_hit:
                        raw_score += 0.95
                        matched.add(keyword)
            confidence = max(0.0, min(1.0, 1.0 - math.exp(-(raw_score / 4.0))))
            reason = "Matched keywords: " + ", ".join(sorted(matched)) if matched else "Low deterministic signal."
            scored[definition.category] = (confidence, reason[:180])
        return scored

    def _compose_actions(self, *, domain_scores: dict[str, tuple[float, str]], limit: int) -> list[dict[str, Any]]:
        ranked = sorted(
            (
                (category, confidence_reason[0], confidence_reason[1])
                for category, confidence_reason in domain_scores.items()
                if category in DOMAIN_BY_CATEGORY
            ),
            key=lambda item: (item[1], item[0]),
            reverse=True,
        )

        selected_domains: list[tuple[str, float, str]] = [item for item in ranked if item[1] >= DOMAIN_THRESHOLD][:2]

        if len(selected_domains) < 2 and ranked:
            for category, confidence, reason in ranked:
                if any(existing[0] == category for existing in selected_domains):
                    continue
                selected_domains.append((category, max(confidence, DOMAIN_THRESHOLD), reason or "Fallback domain candidate."))
                if len(selected_domains) >= 2:
                    break

        actions: list[dict[str, Any]] = []
        for index, (category, confidence, reason) in enumerate(selected_domains[:2], start=1):
            template = DOMAIN_BY_CATEGORY[category]
            actions.append(
                {
                    "id": f"qa-{category}-{index}",
                    "label": template.label,
                    "prompt": template.prompt,
                    "category": category,
                    "confidence": round(max(0.0, min(confidence, 1.0)), 3),
                    "reason": reason,
                }
            )

        if not actions:
            return self._general_actions(limit=limit)

        general_needed = max(0, limit - len(actions))
        actions.extend(self._general_actions(limit=general_needed))
        return actions[:limit]

    def _general_actions(self, *, limit: int) -> list[dict[str, Any]]:
        items: list[dict[str, Any]] = []
        for template in GENERAL_ACTIONS[: max(0, limit)]:
            items.append(
                {
                    "id": template["id"],
                    "label": template["label"],
                    "prompt": template["prompt"],
                    "category": "general",
                    "confidence": 0.25,
                    "reason": template["reason"],
                }
            )
        return items
