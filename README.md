# Stash

Stash is a macOS menu bar app that lets you quickly capture PDFs, notes, questions, and highlighted text into **Projects**, then generates **grounded insights**, **follow‑up questions**, and **answers** using OpenAI’s Responses API with File Search (vector stores). It is **BYOK (bring your own OpenAI API key)** for the MVP and stores your originals and derived artifacts locally, with per‑project control over what’s uploaded.

## Why Stash
- Capture becomes effortless.
- Project context becomes coherent.
- Answers are grounded in your materials.
- Insight generation happens automatically, but stays controllable.

## MVP Scope
- macOS menu bar app with an always‑on‑top overlay
- Project creation and fast Project switching
- Drag‑and‑drop PDFs into the overlay
- Quick note / question input
- Capture selected text via “save clipboard” hotkey
- Automatic processing on new inputs (configurable)
- Project‑scoped Q&A chat
- Project window to browse inputs, outputs, and activity
- Feedback on outputs (thumbs up/down)
- Settings: API key, per‑project upload toggle, concurrency, notifications

## Core Objects
- **Projects**: the primary container
- **Inputs**: PDFs, notes, questions, snippets
- **Outputs**: brief, insights, open questions, suggested questions, action items, answers
- **Runs**: background jobs that ingest and generate outputs

## High‑Level Architecture
- **UI (SwiftUI/AppKit)**: menu bar, overlay, Projects window
- **Local data layer**: SQLite or Core Data
- **File storage**: `~/Library/Application Support/Stash/Projects/<project_id>/`
- **Background worker**: PDF extraction, chunking, indexing, Responses calls
- **OpenAI stack**: Responses API + File Search (vector stores), optional Agents SDK

## Output Expectations (Structured)
- **Project brief**: summary, objectives, constraints, stakeholders, assumptions, unknowns
- **Key insights**: statements with confidence + evidence
- **Open questions**: grouped by theme
- **Suggested next questions**: “ask this next” list
- **Action items**: decisions, next steps, agenda
- **Q&A answers**: grounded answer + sources + missing info

## Principles
- Local‑first: originals and outputs stored locally
- Grounded: answers only from project materials
- Transparent: clear processing and upload controls
- Fast: overlay appears instantly, results stream quickly

## Status
Backend foundation is now implemented under `backend-service/`:

- FastAPI local service on `localhost`
- Folder-scoped project state in `.stash/` for portable resume/history
- SQLite metadata + conversations/runs/events
- Local vector indexing/search
- Background file watching/indexing
- Tagged Codex command execution in controlled worktrees

See `backend-service/README.md` for setup and API usage.

## License
TBD
