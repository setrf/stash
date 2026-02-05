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
