from __future__ import annotations

from dataclasses import dataclass

from .codex import CodexExecutor
from .config import Settings
from .indexer import IndexingService
from .orchestrator import RunOrchestrator
from .planner import Planner
from .project_store import ProjectStore
from .runtime_config import RuntimeConfigStore
from .watcher import WatcherService


@dataclass
class Services:
    settings: Settings
    runtime_config: RuntimeConfigStore
    project_store: ProjectStore
    indexer: IndexingService
    watcher: WatcherService
    planner: Planner
    codex: CodexExecutor
    orchestrator: RunOrchestrator


def build_services(settings: Settings) -> Services:
    runtime_config = RuntimeConfigStore(settings)
    project_store = ProjectStore()
    indexer = IndexingService(settings)
    planner = Planner(settings, runtime_config_store=runtime_config)
    codex = CodexExecutor(settings, runtime_config_store=runtime_config)
    watcher = WatcherService(
        project_store=project_store,
        indexer=indexer,
        scan_interval_seconds=settings.scan_interval_seconds,
    )
    orchestrator = RunOrchestrator(
        project_store=project_store,
        indexer=indexer,
        planner=planner,
        codex=codex,
        runtime_config_store=runtime_config,
    )

    return Services(
        settings=settings,
        runtime_config=runtime_config,
        project_store=project_store,
        indexer=indexer,
        watcher=watcher,
        planner=planner,
        codex=codex,
        orchestrator=orchestrator,
    )
