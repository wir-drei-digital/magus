# Knowledge Brain

Markdown-native knowledge base: each brain is a tree of pages whose single source of truth is a markdown body, edited by users in the SPA and read/written by agents through tools.

## Overview

A brain collects what a user (or an agent working for them) knows about a topic: pages of markdown linked with `[[wikilinks]]`, tagged, nested arbitrarily deep, and searchable semantically together with ingested web sources. Agents treat pages like files: read, write, string-edit, undo. The Brain is distinct from the [Super Brain](./15-super-brain.md), which is a derived knowledge graph built from brain pages (among other sources); typed relationships such as supports/contradicts live there, not here.

## Data model

- **BrainResource** (`brains`): title, description, icon, color, `instructions` (the Guide constitution), optional `workspace_id` (null = personal), archivable.
- **Page** (`brain_pages`): `body` is a markdown string with optional YAML frontmatter and is the only content storage. `frontmatter` is a cached parsed copy for cheap filtering. `kind` is `:page` or `:template` (templates are reusable starting points, excluded from listings and search). Arbitrary nesting via `parent_page_id` with fractional `position`. Untitled pages with enough content get an LLM-generated title via an AshOban trigger.
- **Trash**: `soft_delete` stamps `deleted_at` (subtree hidden via ancestor filter), `restore` brings the subtree back, a daily Oban job hard-deletes after 30 days.
- **Legacy**: `Magus.Brain.Block` is a read-only view of the old `brain_blocks` table kept for migration tooling and slated for deletion. Blocks and Connections are no longer part of the model.

### The single write path: `update_body`

All content writes go through `Page.update_body` (`lib/magus/brain/page.ex`):

1. Optimistic lock: callers pass `base_version`; a mismatch with `lock_version` returns a structured `VersionConflict` carrying the current body so editors and tools can recover without another round trip.
2. `UpdateBodyDerivedState` rebuilds every derived index in the same transaction: frontmatter cache, page links, sources, tags, and page chunks.
3. Every successful save produces an AshPaperTrail version (snapshot mode). Version history powers the Activity feed, token-level diffs, and restore; restoring writes the snapshot back through `update_body`, so it is itself a versioned, locked save.
4. Super Brain extraction is enqueued as an after-action.

The SPA's TipTap editor saves via `save_prosemirror` (ProseMirror JSON converted to markdown server-side, then `update_body`), so UI and agent writes share the exact same pipeline.

### Derived indexes (read-only outside the save pipeline)

- **PageLink** (`brain_page_links`): `[[Page Name]]` wikilinks, resolved case-insensitively within the brain. Powers backlinks. `target_title_at_link_time` lets the UI flag rename drift; bodies are never rewritten on rename.
- **PageTag** (`brain_page_tags`): tags from the frontmatter `tags:` list plus inline `#tag`; frontmatter wins on overlap.
- **Source + PageSource** (`brain_sources`, `brain_page_sources`): fenced ```source blocks in a body upsert Source rows keyed by `(brain_id, url)`; an Oban IngestWorker fetches and extracts the content, a ChunkWorker chunks it. PageSource preserves document order.
- **PageChunk / SourceChunk**: content chunks (frontmatter stripped) written at save/ingest time; embeddings filled in asynchronously by per-minute AshOban triggers (pgvector).

## Guides (ICM)

Each brain carries an agent-maintained "Guide" that keeps its organization legible (see `docs/superpowers/specs/2026-07-07-brain-guides-icm.md`):

- **Constitution**: brain-wide instructions stored on `brain.instructions`.
- **Section guides**: `instructions:` frontmatter on a page, inherited by every descendant.
- **Types**: agent-defined vocabulary. A `:template` page defines a type; a page's `type:` frontmatter classifies it against that template.

`Magus.Brain.Guide` assembles the effective Guide for a page's location (constitution, ancestor section guides, types index). It is injected into the agent's system prompt, returned on demand by the `brain_guide` tool, and shown to users in the SPA page's Guide tab so both sides see the same rules. Guidance is soft: violations surface as curation candidates (see below), never hard errors.

## Search

Entry points in `Magus.Brain` (`lib/magus/brain/brain.ex`):

- `search_chunks/3`: pgvector cosine search over PageChunk + SourceChunk, cross-brain when no `brain_id` is given (scoped to brains the actor can access).
- `search_pages_text/3`: Postgres full-text search over `brain_pages.search_vector`, used as fallback when embedding generation fails.
- `search_with_files/3`: additionally searches file chunks for files referenced from page bodies via `magus://file/...` links.

Templates and trashed pages are excluded everywhere.

## Agent access

Three tools in `lib/magus/agents/tools/brain/`, with `BrainResolver` accepting brain id, slug, or title and auto-resolving from context:

- **read_brain**: list_brains, list_pages, find_page (title + FTS), search (semantic, pages/sources), get_backlinks, list_tags, read_page / peek_page, read_source, and list_curation_candidates (metadata-only maintenance scan: drifted, stale, orphans, untyped, off_template, dangling_type, unfiled) for heartbeat-driven curation.
- **edit_brain**: create_brain, write_page (create/replace/append/prepend, slash-paths auto-create ancestors), edit_page (string match or line-range), multi_edit (atomic batch), clear_page, undo_last_edit (paper-trail restore), rename_page, move_page, delete_page (to trash). Lock conflicts auto-retry once where safe; line-range edits surface the conflict instead.
- **brain_guide**: get_guide, set_brain_guide, set_page_guide, define_type, set_page_type.

Context injection (`lib/magus/agents/context/`):

- **BrainContext** injects the brain's structure, the active page's body preview, and its Guide into the system prompt when a brain page is in scope. Companion chats (`Magus.Chat.ConversationCompanion` links a conversation to a brain page; the SPA's per-page "Open chat") get the full page tree instead of just the neighborhood around the active page.
- **BrainRagContext** runs on every message regardless of any open pane: it embeds the query and injects the top page/source chunk hits across all accessible brains, falling back to FTS.

## Access control

Brains use the shared workspace-scoped grant model (`workspace_scoped_policies(resource_type: :brain)`); pages and derived indexes check through `BrainAccessFilter` with `:viewer` for reads and `:editor` for writes.
