from __future__ import annotations

from dataclasses import dataclass

from .codex import CodexExecutor
from .config import Settings
from .indexer import IndexingService
from .orchestrator import RunOrchestrator
from .planner import Planner
from .project_store import ProjectStore
from .watcher import WatcherService


@dataclass
class Services:
    settings: Settings
    project_store: ProjectStore
    indexer: IndexingService
    watcher: WatcherService
    planner: Planner
    codex: CodexExecutor
    orchestrator: RunOrchestrator


def build_services(settings: Settings) -> Services:
    project_store = ProjectStore()
    indexer = IndexingService(settings)
    planner = Planner(settings)
    codex = CodexExecutor(settings)
    watcher = WatcherService(
        project_store=project_store,
        indexer=indexer,
        scan_interval_seconds=settings.scan_interval_seconds,
    )
    orchestrator = RunOrchestrator(project_store=project_store, planner=planner, codex=codex)

    return Services(
        settings=settings,
        project_store=project_store,
        indexer=indexer,
        watcher=watcher,
        planner=planner,
        codex=codex,
        orchestrator=orchestrator,
    )
