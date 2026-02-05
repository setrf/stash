from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


class ProjectCreateRequest(BaseModel):
    name: str = Field(min_length=1)
    root_path: str = Field(min_length=1)


class ProjectPatchRequest(BaseModel):
    name: str | None = None
    active_conversation_id: str | None = None


class ProjectResponse(BaseModel):
    id: str
    name: str
    root_path: str
    created_at: str | None = None
    last_opened_at: str | None = None
    active_conversation_id: str | None = None
    permission: dict[str, Any] | None = None


class ConversationCreateRequest(BaseModel):
    title: str = "New Conversation"
    start_mode: Literal["manual", "proactive"] = "manual"


class ConversationPatchRequest(BaseModel):
    title: str | None = None
    status: Literal["active", "archived"] | None = None
    pinned: bool | None = None
    summary: str | None = None


class ConversationForkRequest(BaseModel):
    from_message_id: str | None = None
    title: str | None = None


class ConversationResponse(BaseModel):
    id: str
    project_id: str
    title: str
    status: str
    pinned: bool
    created_at: str
    last_message_at: str | None = None
    summary: str | None = None


class MessageCreateRequest(BaseModel):
    role: Literal["user", "assistant", "tool", "system"] = "user"
    content: str = Field(min_length=1)
    parts: list[dict[str, Any]] = Field(default_factory=list)
    parent_message_id: str | None = None
    asset_ids: list[str] = Field(default_factory=list)
    mode: Literal["manual", "proactive"] = "manual"
    start_run: bool = True
    idempotency_key: str | None = None


class MessagePatchRequest(BaseModel):
    metadata: dict[str, Any] | None = None
    superseded: bool | None = None


class MessageResponse(BaseModel):
    id: str
    project_id: str
    conversation_id: str
    role: str
    content: str
    parts: list[dict[str, Any]]
    parent_message_id: str | None = None
    sequence_no: int
    created_at: str
    superseded_by: str | None = None
    metadata: dict[str, Any] = Field(default_factory=dict)


class RunResponse(BaseModel):
    id: str
    project_id: str
    conversation_id: str
    trigger_message_id: str
    status: str
    mode: str
    output_summary: str | None = None
    error: str | None = None
    created_at: str
    finished_at: str | None = None


class AssetCreateRequest(BaseModel):
    kind: Literal["file", "link", "note"]
    title: str | None = None
    path_or_url: str | None = None
    content: str | None = None
    tags: list[str] = Field(default_factory=list)
    auto_index: bool = True


class AssetResponse(BaseModel):
    id: str
    project_id: str
    kind: str
    title: str | None = None
    path_or_url: str | None = None
    content: str | None = None
    tags: list[str] = Field(default_factory=list)
    created_at: str
    updated_at: str
    indexed_at: str | None = None


class IndexRequest(BaseModel):
    full_scan: bool = True


class IndexJobResponse(BaseModel):
    job_id: str
    project_id: str
    status: str
    started_at: str
    finished_at: str | None = None
    detail: dict[str, Any] = Field(default_factory=dict)


class SearchRequest(BaseModel):
    query: str = Field(min_length=1)
    limit: int = Field(default=10, ge=1, le=100)


class SearchHit(BaseModel):
    asset_id: str
    chunk_id: str
    score: float
    text: str
    title: str | None = None
    path_or_url: str | None = None


class SearchResponse(BaseModel):
    query: str
    hits: list[SearchHit]


class HistorySearchRequest(BaseModel):
    query: str = Field(min_length=1)
    limit: int = Field(default=20, ge=1, le=100)
    include_archived: bool = True


class CodexExecuteRequest(BaseModel):
    payload: str
    conversation_id: str | None = None
    run_id: str | None = None


class CodexExecuteResponse(BaseModel):
    commands_executed: int
    results: list[dict[str, Any]]


class TaskStatusResponse(BaseModel):
    message_id: str
    run_id: str | None = None
    status: str


class RuntimeConfigResponse(BaseModel):
    planner_backend: Literal["auto", "codex_cli", "openai_api"]
    codex_mode: Literal["cli", "shell"]
    codex_bin: str
    codex_planner_model: str
    planner_cmd: str | None = None
    planner_timeout_seconds: int
    planner_mode: Literal["fast", "balanced", "quality"]
    execution_mode: Literal["planner", "execute"]
    execution_parallel_reads_enabled: bool
    execution_parallel_reads_max_workers: int
    openai_api_key_set: bool
    openai_model: str
    openai_base_url: str
    openai_timeout_seconds: int
    config_path: str


class RuntimeConfigUpdateRequest(BaseModel):
    planner_backend: Literal["auto", "codex_cli", "openai_api"] | None = None
    codex_mode: Literal["cli", "shell"] | None = None
    codex_bin: str | None = None
    codex_planner_model: str | None = None
    planner_cmd: str | None = None
    clear_planner_cmd: bool = False
    planner_timeout_seconds: int | None = Field(default=None, ge=20, le=600)
    planner_mode: Literal["fast", "balanced", "quality"] | None = None
    execution_mode: Literal["planner", "execute"] | None = None
    execution_parallel_reads_enabled: bool | None = None
    execution_parallel_reads_max_workers: int | None = Field(default=None, ge=1, le=8)
    openai_api_key: str | None = None
    clear_openai_api_key: bool = False
    openai_model: str | None = None
    openai_base_url: str | None = None
    openai_timeout_seconds: int | None = Field(default=None, ge=5, le=300)
