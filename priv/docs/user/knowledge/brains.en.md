---
title: Knowledge Brain
description: A collaborative research workspace where you and your AI build understanding together
order: 6
---

# Knowledge Brain

A Knowledge Brain is a shared workspace for you and your AI to research, write, and organize ideas around a topic. Think of it as a personal wiki that you build together. Unlike memory, which stores facts the AI recalls automatically, a Brain is a place you actively build. You write notes, collect sources, and ask questions, with the AI as a thinking partner at every step.

Each Brain contains pages, and every page is a markdown document. What you write in the editor is stored as plain, portable markdown, and the AI reads and edits exactly the same text you do. No hidden format, no lock-in.

## Getting Started

### Creating a Brain

Switch to **Brain** mode in the sidebar and click **New brain**. Give it a name, usually the topic or project you are researching. You can create as many brains as you like. Keeping each one focused on a single topic gives the AI clear context.

### Creating Pages

Hover over a brain in the sidebar and click the plus button to create a page. Pages can nest as deep as you like: hover over any page and click the plus to add a sub-page beneath it. Click the title in the page header to rename a page. If you leave a page untitled, Magus names it for you once it has some content.

### Two Places to Work

- **Brain view**: click a page in the sidebar to open it full-size. Click **Open chat** in the page header to dock a conversation right next to the page.
- **In a chat**: open the **Brains** panel in the right rail and pick a page. It opens as a side pane next to your conversation.

Either way, the AI automatically sees the open page, so you can talk about it without copying anything. When others have the same page open, their avatars appear in the header.

## The Editor

Pages open in a rich text editor. Type `/` to insert a block: headings, bullet and numbered lists, quotes, code blocks, tables, images, dividers, and collapsible toggle sections. Type `[ ]` at the start of a line for a checklist item, and `#tag` anywhere to tag the page. The AI can additionally write callout boxes for highlighted notes.

- Select text to get a formatting bubble, plus **Ask** and **Refine** (see below).
- Drag the handle at the left edge of a block to reorder it.
- Drop or paste images and files straight into the page, or click **Add file** to insert something from your file library.

### Linking Pages

Type `[[` anywhere to link to another page in the same brain. A suggestion list appears as you type the name; pick a page to insert a `[[Page Name]]` link. Links are clickable, and the **Related** tab shows every page that links back to the one you are reading.

### The Tabs Under the Page

At the bottom of every page you find:

- **Tasks**: a task board for tasks that live on this page
- **Outline**: the headings on the page; click one to jump there
- **Sources**: web sources referenced on this page, with links to the originals
- **Related**: pages that link to this one
- **Activity**: the page's full edit history (see Version History)
- **Guide**: the organization rules that apply to this page (see The Guide)

## Working with the AI

With a page open next to a conversation, the AI is a full collaborator:

- **Ask about a selection**: highlight text in the editor and click **Ask** to send it to the chat as context for your next question.
- **Refine a selection**: click **Refine**, type an instruction like "make this more concise", and the AI reworks that passage.
- **Let it write**: share your thoughts in the chat and ask for a page. The AI writes well-structured markdown with headings, lists, links, and more.
- **Let it edit**: the AI can append to pages, make precise text edits, create sub-pages, rename and move pages, and undo its own last edit if you ask.
- **Let it research**: when the AI searches the web while working in a brain, it can save what it finds as sources. Their content is fetched and indexed, so you can ask questions about the material afterwards. The **Sources** tab lists everything referenced on a page.

Your brains also work for you outside the Brain view: in any conversation, the AI automatically pulls in relevant snippets from your pages and sources when they match what you are asking about.

## Dropping Notes into Conversation

You do not need to open a page to add knowledge. Just share notes, facts, or findings naturally in any conversation. The AI searches your brains for a page on that topic, appends to it if one exists, or creates a new page with a fitting title, and briefly tells you what it did. If you have several brains (say Work and Personal), it routes content to the right one and asks when it is unsure.

## The Guide

Each brain can carry a Guide: the rules for how it should be organized. The AI follows the Guide whenever it writes to or tidies the brain, and the **Guide** tab on every page shows you exactly which rules apply there.

- **Constitution**: brain-wide instructions, for example "every page starts with a one-line summary" or "ask before restructuring". Edit it under **Brain settings** (hover the brain in the sidebar and click the gear), or let the AI propose one as the brain takes shape.
- **Section guides**: instructions attached to a page that apply to everything beneath it. Ask the AI to set them, for example "in the Meetings section, every page should start with a date".
- **Types and templates**: the AI can define page types (like "meeting note" or "book summary"), each backed by a template page. Templates live in a **Templates** folder in the sidebar, and you can edit them like any other page to change what new pages of that type look like. Brain settings lists all defined types, and a page's Guide tab shows its type.

Guides steer the AI. They never block your own edits.

## Version History

Every save creates a version, whether it came from you, the AI, or a teammate. The **Activity** tab lists them all with a short preview and a timestamp. Click a version to see exactly what changed, with additions and removals highlighted. If it is not the latest version, you can click **Restore this version** to bring it back. A restore is itself a new save, so you can always change your mind again.

## Editing at the Same Time

You, the AI, and your teammates can all work on a page at once. When someone else saves while you are just reading, the page updates in place. When you are mid-edit, every save is checked against the latest version of the page: if it changed under you, you see a notice instead of anything being silently lost. And since every save lands in the version history, you can always recover any state from the **Activity** tab.

## Trash

Click the trash button in the page header (and click again to confirm) to move a page and its sub-pages to the trash. Trashed pages sit in **Trash** at the bottom of the Brain sidebar for 30 days, where a click on **Restore** brings them back, sub-pages included. After 30 days they are deleted permanently.

## Organizing Your Brains

- Keep each brain focused on one topic or project, and use nested pages to break it into sections.
- Use `[[Page Name]]` links liberally. The **Related** tab turns them into a navigation web that makes even large brains easy to explore.
- In **Brain settings** you can change a brain's name, description, icon, and color. For brains in a workspace, a sharing toggle opens them to everyone in that workspace.
- Let the AI do the housekeeping: ask it to restructure sections, fix stale links after renames, or file loose notes where they belong.
