from __future__ import annotations

import asyncio
import json
from dataclasses import asdict
from typing import Any, Literal

from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse, PlainTextResponse, StreamingResponse

from .db import ProjectRepository
from .integrations import codex_integration_status
from .schemas import (
    AssetCreateRequest,
    AssetResponse,
    CodexExecuteRequest,
    CodexExecuteResponse,
    ConversationCreateRequest,
    ConversationForkRequest,
    ConversationPatchRequest,
    ConversationResponse,
    HistorySearchRequest,
    IndexJobResponse,
    IndexRequest,
    MessageCreateRequest,
    MessagePatchRequest,
    MessageResponse,
    ProjectCreateRequest,
    ProjectPatchRequest,
    ProjectResponse,
    RunResponse,
    RuntimeConfigResponse,
    RuntimeConfigUpdateRequest,
    SearchRequest,
    SearchResponse,
    TaskStatusResponse,
)
from .service_container import Services


def _repo_or_404(services: Services, project_id: str) -> tuple[Any, ProjectRepository]:
    context = services.project_store.get(project_id)
    if context is None:
        raise HTTPException(status_code=404, detail="Project not loaded")
    return context, ProjectRepository(context)


def _conversation_or_404(repo: ProjectRepository, conversation_id: str) -> dict[str, Any]:
    conv = repo.get_conversation(conversation_id)
    if conv is None:
        raise HTTPException(status_code=404, detail="Conversation not found")
    return conv


def _message_or_404(repo: ProjectRepository, conversation_id: str, message_id: str) -> dict[str, Any]:
    msg = repo.get_message(conversation_id, message_id)
    if msg is None:
        raise HTTPException(status_code=404, detail="Message not found")
    return msg


def create_app(services: Services) -> FastAPI:
    app = FastAPI(title="Stash Backend", version="0.1.0")

    @app.on_event("shutdown")
    async def _shutdown() -> None:
        await services.watcher.stop()
        services.project_store.close()

    @app.get("/health")
    async def health() -> dict[str, Any]:
        return {"ok": True}

    @app.get("/health/integrations")
    async def health_integrations() -> dict[str, Any]:
        return codex_integration_status(services.runtime_config.get())

    @app.get("/v1/runtime/config", response_model=RuntimeConfigResponse)
    async def get_runtime_config() -> RuntimeConfigResponse:
        return RuntimeConfigResponse(**services.runtime_config.public_view())

    @app.patch("/v1/runtime/config", response_model=RuntimeConfigResponse)
    async def patch_runtime_config(request: RuntimeConfigUpdateRequest) -> RuntimeConfigResponse:
        services.runtime_config.update(
            planner_backend=request.planner_backend,
            codex_mode=request.codex_mode,
            codex_bin=request.codex_bin,
            codex_planner_model=request.codex_planner_model,
            planner_cmd=request.planner_cmd,
            clear_planner_cmd=request.clear_planner_cmd,
            planner_timeout_seconds=request.planner_timeout_seconds,
            planner_mode=request.planner_mode,
            execution_mode=request.execution_mode,
            execution_parallel_reads_enabled=request.execution_parallel_reads_enabled,
            execution_parallel_reads_max_workers=request.execution_parallel_reads_max_workers,
            openai_api_key=request.openai_api_key,
            clear_openai_api_key=request.clear_openai_api_key,
            openai_model=request.openai_model,
            openai_base_url=request.openai_base_url,
            openai_timeout_seconds=request.openai_timeout_seconds,
        )
        return RuntimeConfigResponse(**services.runtime_config.public_view())

    @app.get("/v1/runtime/setup-status")
    async def runtime_setup_status() -> dict[str, Any]:
        return codex_integration_status(services.runtime_config.get())

    @app.post("/v1/projects", response_model=ProjectResponse)
    async def create_or_open_project(request: ProjectCreateRequest) -> ProjectResponse:
        try:
            context = services.project_store.open_or_create(name=request.name, root_path=request.root_path)
        except PermissionError as exc:
            raise HTTPException(status_code=403, detail=str(exc)) from exc

        repo = ProjectRepository(context)

        # Ensure at least one conversation for quick resume.
        if not repo.list_conversations(limit=1):
            repo.create_conversation("General")

        services.watcher.ensure_project_watch(context.project_id)

        project = repo.project_view()
        project["permission"] = asdict(context.permission) if context.permission else None
        return ProjectResponse(**project)

    @app.get("/v1/projects", response_model=list[ProjectResponse])
    async def list_projects() -> list[ProjectResponse]:
        responses: list[ProjectResponse] = []
        for context in services.project_store.list_projects():
            repo = ProjectRepository(context)
            project = repo.project_view()
            project["permission"] = asdict(context.permission) if context.permission else None
            responses.append(ProjectResponse(**project))
        return responses

    @app.get("/v1/projects/{project_id}", response_model=ProjectResponse)
    async def get_project(project_id: str) -> ProjectResponse:
        context, repo = _repo_or_404(services, project_id)
        project = repo.project_view()
        project["permission"] = asdict(context.permission) if context.permission else None
        return ProjectResponse(**project)

    @app.patch("/v1/projects/{project_id}", response_model=ProjectResponse)
    async def patch_project(project_id: str, request: ProjectPatchRequest) -> ProjectResponse:
        context, repo = _repo_or_404(services, project_id)
        updated = repo.update_project(name=request.name, active_conversation_id=request.active_conversation_id)
        updated["permission"] = asdict(context.permission) if context.permission else None
        return ProjectResponse(**updated)

    @app.get("/v1/projects/{project_id}/permissions")
    async def get_permissions(project_id: str) -> dict[str, Any]:
        context, _repo = _repo_or_404(services, project_id)
        return asdict(context.permission) if context.permission else {}

    @app.post("/v1/projects/{project_id}/conversations", response_model=ConversationResponse)
    async def create_conversation(project_id: str, request: ConversationCreateRequest) -> ConversationResponse:
        _context, repo = _repo_or_404(services, project_id)
        conv = repo.create_conversation(title=request.title)
        repo.add_event("conversation_created", conversation_id=conv["id"], payload={"title": conv["title"]})
        return ConversationResponse(**conv)

    @app.get("/v1/projects/{project_id}/conversations", response_model=list[ConversationResponse])
    async def list_conversations(
        project_id: str,
        cursor: str | None = None,
        limit: int = Query(default=50, ge=1, le=200),
        status: Literal["active", "archived"] | None = None,
        pinned: bool | None = None,
        q: str | None = None,
    ) -> list[ConversationResponse]:
        _context, repo = _repo_or_404(services, project_id)
        items = repo.list_conversations(status=status, pinned=pinned, q=q, limit=limit, cursor=cursor)
        return [ConversationResponse(**item) for item in items]

    @app.get("/v1/projects/{project_id}/conversations/{conversation_id}", response_model=ConversationResponse)
    async def get_conversation(project_id: str, conversation_id: str) -> ConversationResponse:
        _context, repo = _repo_or_404(services, project_id)
        conv = _conversation_or_404(repo, conversation_id)
        return ConversationResponse(**conv)

    @app.patch("/v1/projects/{project_id}/conversations/{conversation_id}", response_model=ConversationResponse)
    async def patch_conversation(project_id: str, conversation_id: str, request: ConversationPatchRequest) -> ConversationResponse:
        _context, repo = _repo_or_404(services, project_id)
        updated = repo.update_conversation(
            conversation_id,
            title=request.title,
            status=request.status,
            pinned=request.pinned,
            summary=request.summary,
        )
        if updated is None:
            raise HTTPException(status_code=404, detail="Conversation not found")
        repo.add_event("conversation_updated", conversation_id=conversation_id, payload=updated)
        return ConversationResponse(**updated)

    @app.post("/v1/projects/{project_id}/conversations/{conversation_id}/fork", response_model=ConversationResponse)
    async def fork_conversation(project_id: str, conversation_id: str, request: ConversationForkRequest) -> ConversationResponse:
        _context, repo = _repo_or_404(services, project_id)
        forked = repo.fork_conversation(conversation_id, from_message_id=request.from_message_id, title=request.title)
        if forked is None:
            raise HTTPException(status_code=404, detail="Conversation or source message not found")
        repo.add_event("conversation_created", conversation_id=forked["id"], payload={"forked_from": conversation_id})
        return ConversationResponse(**forked)

    @app.get("/v1/projects/{project_id}/conversations/{conversation_id}/transcript")
    async def transcript(project_id: str, conversation_id: str, format: Literal["json", "markdown"] = "json") -> Any:
        _context, repo = _repo_or_404(services, project_id)
        conv = _conversation_or_404(repo, conversation_id)
        messages = repo.transcript(conversation_id)

        if format == "json":
            return {"conversation": conv, "messages": messages}

        lines = [f"# Transcript - {conv['title']}", ""]
        for msg in messages:
            lines.append(f"## {msg['role'].title()} ({msg['created_at']})")
            lines.append("")
            lines.append(msg["content"])
            lines.append("")
        return PlainTextResponse("\n".join(lines), media_type="text/markdown")

    @app.post("/v1/projects/{project_id}/conversations/{conversation_id}/messages", response_model=TaskStatusResponse)
    async def create_message(project_id: str, conversation_id: str, request: MessageCreateRequest) -> TaskStatusResponse:
        _context, repo = _repo_or_404(services, project_id)
        _conversation_or_404(repo, conversation_id)

        message = repo.create_message(
            conversation_id,
            role=request.role,
            content=request.content,
            parts=request.parts,
            parent_message_id=request.parent_message_id,
            metadata={"idempotency_key": request.idempotency_key} if request.idempotency_key else {},
        )

        for asset_id in request.asset_ids:
            repo.create_message_attachment(message["id"], asset_id)

        repo.add_event(
            "message_created",
            conversation_id=conversation_id,
            payload={"message_id": message["id"], "role": message["role"]},
        )

        if request.start_run and request.role == "user":
            run = services.orchestrator.start_run(
                project_id=project_id,
                conversation_id=conversation_id,
                trigger_message_id=message["id"],
                mode=request.mode,
            )
            return TaskStatusResponse(message_id=message["id"], run_id=run["id"], status="running")

        return TaskStatusResponse(message_id=message["id"], run_id=None, status="done")

    @app.get("/v1/projects/{project_id}/conversations/{conversation_id}/messages", response_model=list[MessageResponse])
    async def list_messages(
        project_id: str,
        conversation_id: str,
        cursor: int | None = Query(default=None),
        limit: int = Query(default=200, ge=1, le=1000),
    ) -> list[MessageResponse]:
        _context, repo = _repo_or_404(services, project_id)
        _conversation_or_404(repo, conversation_id)
        messages = repo.list_messages(conversation_id, cursor=cursor, limit=limit)
        return [MessageResponse(**m) for m in messages]

    @app.patch("/v1/projects/{project_id}/conversations/{conversation_id}/messages/{message_id}", response_model=MessageResponse)
    async def patch_message(project_id: str, conversation_id: str, message_id: str, request: MessagePatchRequest) -> MessageResponse:
        _context, repo = _repo_or_404(services, project_id)
        _conversation_or_404(repo, conversation_id)
        _message_or_404(repo, conversation_id, message_id)

        if request.superseded:
            updated = repo.mark_message_superseded(conversation_id, message_id)
            if updated is None:
                raise HTTPException(status_code=404, detail="Message not found")
            return MessageResponse(**updated)

        # Metadata patching is represented as appending a system message for auditability.
        if request.metadata:
            patched = repo.create_message(
                conversation_id,
                role="system",
                content=f"Message {message_id} metadata updated",
                parts=[],
                parent_message_id=message_id,
                metadata=request.metadata,
            )
            return MessageResponse(**patched)

        msg = _message_or_404(repo, conversation_id, message_id)
        return MessageResponse(**msg)

    @app.post("/v1/projects/{project_id}/conversations/{conversation_id}/messages/{message_id}/retry", response_model=TaskStatusResponse)
    async def retry_message(project_id: str, conversation_id: str, message_id: str) -> TaskStatusResponse:
        _context, repo = _repo_or_404(services, project_id)
        _conversation_or_404(repo, conversation_id)
        _message_or_404(repo, conversation_id, message_id)

        run = services.orchestrator.start_run(
            project_id=project_id,
            conversation_id=conversation_id,
            trigger_message_id=message_id,
            mode="manual",
        )
        return TaskStatusResponse(message_id=message_id, run_id=run["id"], status="running")

    @app.get("/v1/projects/{project_id}/runs/{run_id}")
    async def get_run(
        project_id: str,
        run_id: str,
        include_output: bool = Query(default=False),
        output_char_limit: int = Query(default=4000, ge=200, le=20000),
    ) -> dict[str, Any]:
        _context, repo = _repo_or_404(services, project_id)
        run = repo.get_run(run_id)
        if run is None:
            raise HTTPException(status_code=404, detail="Run not found")
        run["steps"] = repo.list_run_steps(
            run_id,
            include_output=include_output,
            output_char_limit=output_char_limit if include_output else None,
        )
        return run

    @app.post("/v1/projects/{project_id}/runs/{run_id}/cancel", response_model=RunResponse)
    async def cancel_run(project_id: str, run_id: str) -> RunResponse:
        result = await services.orchestrator.cancel_run(project_id=project_id, run_id=run_id)
        if result is None:
            raise HTTPException(status_code=404, detail="Run not found")
        return RunResponse(**result)

    @app.post("/v1/projects/{project_id}/assets", response_model=AssetResponse)
    async def create_asset(project_id: str, request: AssetCreateRequest) -> AssetResponse:
        context, repo = _repo_or_404(services, project_id)

        if request.kind == "file" and not request.path_or_url:
            raise HTTPException(status_code=400, detail="path_or_url is required for file assets")

        asset = repo.create_or_update_asset(
            kind=request.kind,
            title=request.title,
            path_or_url=request.path_or_url,
            content=request.content,
            tags=request.tags,
        )

        if request.auto_index:
            result = await asyncio.to_thread(services.indexer.index_asset, context, repo, asset["id"])
            repo.add_event("indexing_progress", payload={"asset_id": asset["id"], "result": result})

        fresh = repo.get_asset(asset["id"])
        return AssetResponse(**fresh)  # type: ignore[arg-type]

    @app.post("/v1/projects/{project_id}/index", response_model=IndexJobResponse)
    async def trigger_index(project_id: str, request: IndexRequest) -> IndexJobResponse:
        _context, _repo = _repo_or_404(services, project_id)
        job = (
            services.watcher.start_full_reindex(project_id)
            if request.full_scan
            else services.watcher.start_incremental_reindex(project_id)
        )
        return IndexJobResponse(
            job_id=job.job_id,
            project_id=job.project_id,
            status=job.status,
            started_at=job.started_at,
            finished_at=job.finished_at,
            detail=job.detail,
        )

    @app.get("/v1/projects/{project_id}/index/jobs/{job_id}", response_model=IndexJobResponse)
    async def get_index_job(project_id: str, job_id: str) -> IndexJobResponse:
        _context, _repo = _repo_or_404(services, project_id)
        job = services.watcher.get_job(job_id)
        if job is None or job.project_id != project_id:
            raise HTTPException(status_code=404, detail="Index job not found")
        return IndexJobResponse(
            job_id=job.job_id,
            project_id=job.project_id,
            status=job.status,
            started_at=job.started_at,
            finished_at=job.finished_at,
            detail=job.detail,
        )

    @app.post("/v1/projects/{project_id}/search", response_model=SearchResponse)
    async def search(project_id: str, request: SearchRequest) -> SearchResponse:
        _context, repo = _repo_or_404(services, project_id)
        hits = services.indexer.search(repo, query=request.query, limit=request.limit)
        return SearchResponse(query=request.query, hits=hits)

    @app.get("/v1/projects/{project_id}/history")
    async def history(project_id: str, limit: int = Query(default=200, ge=1, le=1000)) -> dict[str, Any]:
        _context, repo = _repo_or_404(services, project_id)
        return {"project_id": project_id, "items": repo.timeline(limit=limit)}

    @app.post("/v1/projects/{project_id}/history/search")
    async def history_search(project_id: str, request: HistorySearchRequest) -> dict[str, Any]:
        _context, repo = _repo_or_404(services, project_id)
        results = repo.history_search(
            query=request.query,
            limit=request.limit,
            include_archived=request.include_archived,
        )
        return {"project_id": project_id, "results": results}

    @app.get("/v1/projects/{project_id}/events/stream")
    async def stream_events(
        project_id: str,
        conversation_id: str | None = None,
        since_id: int = Query(default=0, ge=0),
    ) -> StreamingResponse:
        _context, repo = _repo_or_404(services, project_id)

        async def generator() -> Any:
            last_id = since_id
            while True:
                events = repo.list_events(after_id=last_id, conversation_id=conversation_id, limit=200)
                if events:
                    for event in events:
                        last_id = int(event["id"])
                        payload = json.dumps(event)
                        yield f"id: {last_id}\n"
                        yield f"event: {event['type']}\n"
                        yield f"data: {payload}\n\n"
                else:
                    yield ": ping\n\n"
                await asyncio.sleep(1)

        return StreamingResponse(generator(), media_type="text/event-stream")

    @app.post("/v1/projects/{project_id}/codex/execute", response_model=CodexExecuteResponse)
    async def codex_execute(project_id: str, request: CodexExecuteRequest) -> CodexExecuteResponse:
        context, repo = _repo_or_404(services, project_id)

        try:
            results = await asyncio.to_thread(services.codex.execute_payload, context, request.payload)
        except Exception as exc:
            raise HTTPException(status_code=400, detail=str(exc)) from exc

        formatted: list[dict[str, Any]] = []
        for result in results:
            item = {
                "engine": result.engine,
                "exit_code": result.exit_code,
                "stdout": result.stdout,
                "stderr": result.stderr,
                "started_at": result.started_at,
                "finished_at": result.finished_at,
                "cwd": result.cwd,
                "worktree_path": result.worktree_path,
            }
            formatted.append(item)
            repo.add_event(
                "codex_command_executed",
                conversation_id=request.conversation_id,
                run_id=request.run_id,
                payload={"exit_code": result.exit_code, "cwd": result.cwd, "engine": result.engine},
            )

        return CodexExecuteResponse(commands_executed=len(formatted), results=formatted)

    @app.exception_handler(ValueError)
    async def value_error_handler(_request: Any, exc: ValueError) -> JSONResponse:
        return JSONResponse(status_code=400, content={"detail": str(exc)})

    return app
