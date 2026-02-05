from __future__ import annotations

import asyncio
from typing import Any

from .db import ProjectRepository
from .indexer import IndexingService
from .project_store import ProjectStore
from .types import IndexJob
from .utils import make_id, utc_now_iso


class WatcherService:
    def __init__(self, *, project_store: ProjectStore, indexer: IndexingService, scan_interval_seconds: int):
        self.project_store = project_store
        self.indexer = indexer
        self.scan_interval_seconds = max(2, scan_interval_seconds)
        self._watch_tasks: dict[str, asyncio.Task[None]] = {}
        self._index_jobs: dict[str, IndexJob] = {}
        self._index_tasks: dict[str, asyncio.Task[None]] = {}

    def ensure_project_watch(self, project_id: str) -> None:
        if project_id in self._watch_tasks:
            return

        task = asyncio.create_task(self._watch_loop(project_id))
        self._watch_tasks[project_id] = task

    async def stop(self) -> None:
        for task in list(self._watch_tasks.values()):
            task.cancel()
        for task in list(self._index_tasks.values()):
            task.cancel()

        await asyncio.gather(*self._watch_tasks.values(), return_exceptions=True)
        await asyncio.gather(*self._index_tasks.values(), return_exceptions=True)

        self._watch_tasks.clear()
        self._index_tasks.clear()

    async def _watch_loop(self, project_id: str) -> None:
        try:
            while True:
                context = self.project_store.get(project_id)
                if context is None:
                    return

                repo = ProjectRepository(context)
                result = await asyncio.to_thread(self.indexer.scan_project_files, context, repo)
                if result["indexed"] or result["removed"]:
                    with context.lock:
                        repo.add_event(
                            "indexing_progress",
                            payload={
                                "mode": "watcher",
                                "indexed": result["indexed"],
                                "skipped": result["skipped"],
                                "removed": result["removed"],
                            },
                        )

                await asyncio.sleep(self.scan_interval_seconds)
        except asyncio.CancelledError:
            return

    def start_full_reindex(self, project_id: str) -> IndexJob:
        context = self.project_store.get(project_id)
        if context is None:
            raise ValueError("Unknown project")

        job = IndexJob(
            job_id=make_id("idx"),
            project_id=project_id,
            status="running",
            started_at=utc_now_iso(),
            detail={"mode": "manual_full_reindex"},
        )
        self._index_jobs[job.job_id] = job

        task = asyncio.create_task(self._run_full_reindex(job.job_id))
        self._index_tasks[job.job_id] = task
        return job

    def get_job(self, job_id: str) -> IndexJob | None:
        return self._index_jobs.get(job_id)

    async def _run_full_reindex(self, job_id: str) -> None:
        job = self._index_jobs.get(job_id)
        if not job:
            return

        context = self.project_store.get(job.project_id)
        if context is None:
            job.status = "failed"
            job.finished_at = utc_now_iso()
            job.detail["error"] = "project not loaded"
            return

        repo = ProjectRepository(context)

        with context.lock:
            repo.add_event("indexing_started", payload={"job_id": job_id, "mode": "manual"})

        try:
            result = await asyncio.to_thread(self.indexer.full_reindex, context, repo)
            job.status = "done"
            job.detail = result
            job.finished_at = utc_now_iso()

            with context.lock:
                repo.add_event("indexing_completed", payload={"job_id": job_id, "result": result})
        except Exception as exc:
            job.status = "failed"
            job.finished_at = utc_now_iso()
            job.detail["error"] = str(exc)
            with context.lock:
                repo.add_event("indexing_failed", payload={"job_id": job_id, "error": str(exc)})
        finally:
            self._index_tasks.pop(job_id, None)
