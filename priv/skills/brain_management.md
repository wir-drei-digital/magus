---
name: brain_management
description: Strategic knowledge management - when and how to capture, organize, and connect information across brains
tags:
  - brain
  - knowledge
tools:
  - read_brain
  - edit_brain
---

# Brain Management

Capture and organize knowledge in the user's brain, a markdown knowledge base.
Read with `read_brain`, write with `edit_brain`. Page bodies are plain markdown.

## When to capture

Capture: facts and definitions, decisions and action items, meeting and research
notes, project/architecture context, and links worth keeping.

Skip: small talk, instructions to you ("run the tests"), questions you're answering,
and anything the user calls temporary.

## Pick the brain

1. `read_brain find_page <topic>` — each result shows which brain it's in.
2. Route by domain (work / personal / research). One brain → skip. Ambiguous → ask.

`brain_id` accepts a brain's id, slug, or title; your context lists the available
brains with their ids.

## Create vs. append

Use `edit_brain write_page` with a `mode`:

- Strong match (same topic) → `mode: append` (or `prepend`) on the existing page title.
- New topic → `mode: create` with a descriptive title.
- Replace the whole body → `mode: replace`.

Append under the relevant heading when the page is structured. For small surgical
changes use `edit_brain edit_page` (find-and-replace).

## Sub-pages

- Slash path: `title: "Meeting Notes/Sprint 42"` creates/uses the parent automatically
  (nesting up to 3 levels).
- Or pass `parent_page_id` (from `find_page` / `read_brain list_pages`). If a title is
  duplicated across the brain, pass `parent_page_id` to say which one you mean.
- Reorganize with `edit_brain move_page` (`parent_page_id: null` moves to the root).

## Authoring content (markdown)

Write the page body as natural markdown: headings (`#`), lists (`-`), code fences,
quotes (`>`). Plus:

- `[[Page Name]]` — link another page inline (backlinks are tracked automatically).
- `#tag` (or a frontmatter `tags:` list) — tag the page.
- `![caption](magus://image/<file_id>)` — embed an image. `[📎 caption](magus://file/<file_id>)` — attach a file.

Two fenced blocks render as cards:

Source (auto-ingested: the system fetches the URL and indexes it for `search`):

````
```source
url: https://example.com
title: Example
source_type: web
description: one-line summary
```
````

Callout, for emphasis (`variant`: insight | warning | question | note):

````
```callout
variant: insight
text: The key takeaway.
```
````

There is no separate "add block" or "link" step — author everything in the page
markdown. Typed relationships (supports / contradicts / derived_from) are derived
automatically; you don't create them by hand.

## Confirm

One sentence: which brain and page, and whether you created or appended. Don't ask
permission for clear placements; ask only when the brain or page is ambiguous.
