from __future__ import annotations

import os
from pathlib import Path
from typing import Any

from .config import Settings
from .db import ProjectRepository
from .embedding import HashingEmbedder, cosine
from .types import ProjectContext

TEXT_EXTENSIONS = {
    ".txt",
    ".md",
    ".rst",
    ".py",
    ".json",
    ".yaml",
    ".yml",
    ".toml",
    ".ini",
    ".cfg",
    ".csv",
    ".tsv",
    ".js",
    ".ts",
    ".tsx",
    ".jsx",
    ".swift",
    ".java",
    ".go",
    ".rs",
    ".c",
    ".cpp",
    ".h",
    ".hpp",
    ".html",
    ".css",
    ".sql",
    ".sh",
    ".zsh",
}


class IndexingService:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.embedder = HashingEmbedder(dim=settings.vector_dim)

    def _is_hidden(self, path: Path, root: Path) -> bool:
        try:
            rel = path.relative_to(root)
        except ValueError:
            return False
        return any(part.startswith(".") for part in rel.parts)

    def _is_text_file(self, path: Path) -> bool:
        if path.suffix.lower() in TEXT_EXTENSIONS:
            return True
        return False

    def _read_text(self, path: Path) -> str:
        data = path.read_bytes()
        if b"\x00" in data:
            return ""
        try:
            return data.decode("utf-8")
        except UnicodeDecodeError:
            return data.decode("utf-8", errors="ignore")

    def _chunk_text(self, text: str) -> list[str]:
        normalized = text.replace("\r\n", "\n").strip()
        if not normalized:
            return []

        chunk_size = self.settings.chunk_size_chars
        overlap = min(self.settings.chunk_overlap_chars, max(0, chunk_size // 2))

        chunks: list[str] = []
        start = 0
        length = len(normalized)
        while start < length:
            end = min(length, start + chunk_size)
            chunks.append(normalized[start:end])
            if end == length:
                break
            start = max(end - overlap, start + 1)
        return chunks

    def index_asset(self, context: ProjectContext, repo: ProjectRepository, asset_id: str) -> dict[str, Any]:
        asset = repo.get_asset(asset_id)
        if not asset:
            return {"asset_id": asset_id, "status": "missing"}

        source_text = ""
        source_ref = asset.get("path_or_url")

        if asset["kind"] == "file":
            if not source_ref:
                repo.set_asset_error(asset_id, "Missing file path")
                return {"asset_id": asset_id, "status": "error", "error": "missing file path"}
            file_path = Path(source_ref)
            if not file_path.exists():
                repo.set_asset_error(asset_id, f"File not found: {source_ref}")
                return {"asset_id": asset_id, "status": "error", "error": "file not found"}
            if file_path.stat().st_size > self.settings.max_file_size_bytes:
                repo.set_asset_error(asset_id, "File too large to index")
                return {"asset_id": asset_id, "status": "skipped", "error": "file too large"}
            if not self._is_text_file(file_path):
                repo.set_asset_error(asset_id, "Unsupported file type for local text index")
                return {"asset_id": asset_id, "status": "skipped", "error": "unsupported type"}
            source_text = self._read_text(file_path)
        elif asset["kind"] == "link":
            title = asset.get("title") or ""
            link = asset.get("path_or_url") or ""
            content = asset.get("content") or ""
            source_text = f"{title}\n{link}\n{content}".strip()
        else:  # note
            source_text = (asset.get("content") or asset.get("title") or "").strip()

        if not source_text:
            repo.set_asset_error(asset_id, "No indexable text content")
            return {"asset_id": asset_id, "status": "skipped", "error": "empty content"}

        chunks = self._chunk_text(source_text)
        if not chunks:
            repo.set_asset_error(asset_id, "No chunks created")
            return {"asset_id": asset_id, "status": "skipped", "error": "no chunks"}

        repo.clear_asset_index(asset_id)
        for index, chunk in enumerate(chunks):
            vector = self.embedder.embed(chunk)
            repo.insert_chunk_with_embedding(
                asset_id=asset_id,
                source_type=asset["kind"],
                source_ref=source_ref,
                text=chunk,
                token_count=max(1, len(chunk.split())),
                vector=vector,
            )
        repo.set_asset_indexed(asset_id)
        return {"asset_id": asset_id, "status": "indexed", "chunks": len(chunks)}

    def scan_project_files(self, context: ProjectContext, repo: ProjectRepository) -> dict[str, Any]:
        indexed = 0
        skipped = 0
        removed = 0

        root = context.root_path
        seen_rel_paths: set[str] = set()

        for dirpath, dirnames, filenames in os.walk(root):
            dir_path = Path(dirpath)
            if dir_path.name == ".stash":
                dirnames[:] = []
                continue
            if not self.settings.enable_hidden_files:
                dirnames[:] = [d for d in dirnames if not d.startswith(".")]

            for filename in filenames:
                if not self.settings.enable_hidden_files and filename.startswith("."):
                    continue
                file_path = dir_path / filename
                if not file_path.is_file():
                    continue
                if self._is_hidden(file_path, root) and not self.settings.enable_hidden_files:
                    continue

                rel_path = str(file_path.relative_to(root))
                seen_rel_paths.add(rel_path)

                try:
                    stat = file_path.stat()
                except OSError:
                    skipped += 1
                    continue

                if stat.st_size > self.settings.max_file_size_bytes:
                    skipped += 1
                    continue
                if not self._is_text_file(file_path):
                    skipped += 1
                    continue

                snapshot = repo.get_file_snapshot(rel_path)
                if snapshot:
                    if float(snapshot["modified_time"]) == float(stat.st_mtime) and int(snapshot["size_bytes"]) == int(stat.st_size):
                        continue

                asset = repo.create_or_update_asset(
                    kind="file",
                    title=file_path.name,
                    path_or_url=str(file_path),
                    content=None,
                    tags=[],
                )
                result = self.index_asset(context, repo, asset["id"])
                if result["status"] == "indexed":
                    indexed += 1
                else:
                    skipped += 1
                repo.upsert_file_snapshot(rel_path=rel_path, modified_time=float(stat.st_mtime), size_bytes=int(stat.st_size))

        snapshots = repo.list_file_snapshots()
        for snap in snapshots:
            if snap["path"] not in seen_rel_paths:
                repo.delete_file_snapshot(snap["path"])
                removed += 1

        return {"indexed": indexed, "skipped": skipped, "removed": removed}

    def full_reindex(self, context: ProjectContext, repo: ProjectRepository) -> dict[str, Any]:
        indexed_assets = 0
        skipped_assets = 0

        for asset in repo.list_assets():
            result = self.index_asset(context, repo, asset["id"])
            if result["status"] == "indexed":
                indexed_assets += 1
            else:
                skipped_assets += 1

        file_result = self.scan_project_files(context, repo)

        return {
            "indexed_assets": indexed_assets,
            "skipped_assets": skipped_assets,
            "file_scan": file_result,
        }

    def search(self, repo: ProjectRepository, *, query: str, limit: int = 10) -> list[dict[str, Any]]:
        query_vec = self.embedder.embed(query)
        hits: list[dict[str, Any]] = []

        for row in repo.list_embeddings():
            vec = row.get("vector")
            if not isinstance(vec, list):
                continue
            score = cosine(query_vec, [float(v) for v in vec])
            if score <= 0:
                continue
            hits.append(
                {
                    "asset_id": row["asset_id"],
                    "chunk_id": row["chunk_id"],
                    "score": score,
                    "text": row["text"],
                    "title": row.get("title"),
                    "path_or_url": row.get("path_or_url"),
                }
            )

        hits.sort(key=lambda item: item["score"], reverse=True)
        return hits[:limit]
