---
name: brain_management
description: Strategic knowledge management - when and how to capture, organize, and connect information across brains as an Interpretable Context Methodology (ICM)
tags:
  - brain
  - knowledge
tools:
  - read_brain
  - edit_brain
  - brain_guide
---

# Brain Management

Capture and organize knowledge in the user's brain, a markdown knowledge base.
Read with `read_brain`, write with `edit_brain`. Page bodies are plain markdown.

## A brain is an ICM, not a dumping ground

A brain is an **Interpretable Context Methodology (ICM)** space: an interpretable,
self-organizing knowledge system whose value comes from its organization, not its
volume. Anyone (agent or user) should be able to look at the brain and see why it's
shaped the way it is. Every write is a chance to keep that legible or to erode it.

## Default instructions (every brain, always)

These are the baseline conventions for any brain, on top of which each brain's own
Guide (see below) adds specifics:

- One concept per page (atomic). Split a page when it grows two distinct subjects.
- Search before create: prefer extending an existing page over creating a
  near-duplicate.
- Every content page declares a `type` (or you classify it).
- Link related pages with `[[wikilinks]]`; keep an index / Map-of-Content page per
  area.
- No orphans: file a new page under a sensible parent and link it from somewhere.
- When unsure how to organize, ask the user a short, specific question.

## When to capture

Capture: facts and definitions, decisions and action items, meeting and research
notes, project/architecture context, and links worth keeping.

Skip: small talk, instructions to you ("run the tests"), questions you're answering,
and anything the user calls temporary.

## Pick the brain

1. `read_brain find_page <topic>`: each result shows which brain it's in.
2. Route by domain (work / personal / research). One brain → skip. Ambiguous → ask.

`brain_id` accepts a brain's id, slug, or title; your context lists the available
brains with their ids.

## Elicit, don't assume

Users are lazy about writing rules but will answer a short question. When creating a
brain, or when a brain is growing without much shape yet, ask a couple of brief,
optional questions instead of guessing or expecting the user to write a spec:

- What's this brain for, roughly?
- Are there page shapes worth standardizing (meeting notes, people, papers, specs)?
- Any filing preferences (how you like things grouped or nested)?

Keep it to a sentence or two, make it easy to skip, and don't block on an answer:
capture the content now and refine organization as you learn more.

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

- `[[Page Name]]`: link another page inline (backlinks are tracked automatically).
- `#tag` (or a frontmatter `tags:` list): tag the page.
- `![caption](magus://image/<file_id>)`: embed an image. `[📎 caption](magus://file/<file_id>)`: attach a file.

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

There is no separate "add block" or "link" step; author everything in the page
markdown. Typed relationships (supports / contradicts / derived_from) are derived
automatically; you don't create them by hand.

## Tasks live on any page

Any page can carry tasks (`create_task` / `update_task` / `list_tasks` / `clear_tasks`
from the Plan domain, keyed by the page). A page with tasks is what used to be called a
"plan": there's no separate plan or spec kind anymore. Add tasks to whatever page
they belong on: a project page, a spec page, a meeting note, anything.

## Read the Guide before you write

Each brain has its own **Guide**: brain-wide instructions (the constitution) plus,
for the page you're working on, inherited section guides and its type's template.
Most of the time this arrives for free as a `### Brain Guide` block already injected
into your context. If you need it explicitly, or for a different page or location,
call `brain_guide get_guide`. Check it before creating or restructuring pages so you
follow that brain's own conventions on top of the defaults above.

## Authoring the Guide

The Guide isn't written by the user; you write and evolve it as you learn the shape of
a brain, using the `brain_guide` tool:

- `set_brain_guide`: set the brain's constitution (brain-wide instructions). Use
  this after eliciting purpose/preferences, or when you notice a pattern worth
  making explicit for the whole brain.
- `set_page_guide`: set a section guide (`instructions:` frontmatter) on a page;
  it's inherited by every page nested under it. Use for area-specific conventions
  (e.g. "pages under Projects/ always link their spec and their owner").
- `define_type`: create or update a per-type template page (title = type name, body
  = the skeleton + guidance for that type). Propose a new type when a page shape
  recurs (roughly 3 or more similar pages), not for a one-off. Reuse an existing type
  unless the new page is clearly distinct; type explosion makes the brain harder to
  read, not easier.
- `set_page_type`: classify a page by setting its `type:` frontmatter. Do this for
  every content page: pick a matching existing type, or classify it and consider
  `define_type` once the shape repeats.

Keep the constitution and section guides short and concrete; they load into every
turn in that brain or subtree, so treat them like CLAUDE.md, not a wiki page.

## Confirm

One sentence: which brain and page, and whether you created or appended. Don't ask
permission for clear placements; ask only when the brain or page is ambiguous.
