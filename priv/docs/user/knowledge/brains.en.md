---
title: Knowledge Brain
description: A collaborative research workspace where you and your AI build understanding together
order: 5
---

# Knowledge Brain

A Knowledge Brain is a shared workspace for you and your AI to research, write, and organize ideas around a topic. Think of it as a personal wiki that you build together. Unlike memory, which stores facts the AI recalls automatically, a Brain is a place you actively build together. You capture sources, write notes, and ask questions, with the AI as a thinking partner at every step.

Each Brain has its own pages, and each page is a rich text document you can edit directly or let the AI contribute to.

## Getting Started

### Creating a Brain

Open the **Brains** tab in the left sidebar. Click **New Brain** and give it a name. Usually the topic or project you are researching.

You can create as many brains as you like. Keep them focused on a single topic so the AI has clear context when the pane is open.

### Creating Pages

Inside a Brain, click **New Page** to create a page. Pages are the main unit of organization. You might have one page per subtopic, one per source review, or one for overall notes. Whatever fits how you think.

### Opening the Brain Pane

Click any Brain page from the sidebar to open it as a side pane next to your conversation. The pane stays open while you chat, and the AI automatically gets the current page as context.

## The Brain Pane

The Brain pane opens to the right of your conversation. At the top you see the page title. Below is the editor, and at the bottom are four tabs: **Outline**, **Sources**, **Related**, and **Activity**.

### Editing in the Pane

The editor is a full rich text environment built on TipTap. You can type directly, paste content, or let the AI write for you.

**Available block types:**

- Paragraphs
- Headings (H1, H2, H3)
- Bullet lists and numbered lists
- Code blocks
- Block quotes
- Dividers

**Rich block types** go beyond plain text:

- **Source blocks**: a fetched URL with extracted title, type, and content
- **File blocks**: an attached file from your Files library
- **Message blocks**: a saved message from a conversation
- **Callout blocks**: highlighted notes or warnings
- **Image blocks**: inline images

### Linking Pages

Type `[[` anywhere in the editor to link to another page in the same Brain. As you type the page name, a suggestion list appears. Select a page to insert a link. These links help you navigate related content and show up in the **Related** tab.

### Bottom Tabs

- **Outline**: a structured view of the headings on the current page, useful for long pages
- **Sources**: all source blocks on the current page at a glance
- **Related**: pages in this Brain that are linked to or from the current page
- **Activity**: a log of recent changes to the page, including contributions from the AI

## Working with Sources

Sources are URLs you want the AI (and yourself) to work from. When you add a source, Magus fetches the page and extracts its content. The result appears as a source block on the page with the title, URL, and source type.

### Adding a Source

Click **Add Source** in the toolbar or paste a URL into the editor and select **Add as Source**. Magus fetches and extracts the content in the background. Once ready, the block shows the page title and a snippet of the extracted text.

The AI can read source content when the Brain pane is open, so you can immediately ask questions about the material you just added.

### Sources Added by the AI

When the AI uses a web search or fetch tool during a conversation, it can add the result as a source block directly to the open Brain page. These AI-added sources are attributed in the Activity log.

## Chat Integration

The Brain pane and your conversation work closely together. Several features let you move content between them.

### Saving Messages to the Brain

When the Brain pane is open, hover over a message to reveal its actions. Click the brain icon to append the message to the current page, or grab the grip handle at the end of the action row to drag the message into a specific spot in the editor. The rest of the message stays selectable, so you can still copy text out of it the usual way. Useful for capturing a particularly good AI response, an important question, or a summary you want to keep.

### Saving Tool Results

When the AI runs a tool (like a web search), the tool result card has an **Add Source** option. This creates a source block on the current Brain page from the URL the tool fetched.

### Selecting Text as Chat Context

Highlight any text in the Brain editor and a small popover appears. Click **Ask Chat** to send the selected text to the chat as context for your next message. This lets you drill into a specific section without copying and pasting.

### Brain Context in the AI

When the Brain pane is open, the AI receives the current page content as part of its context for every message. You do not need to copy or explain what is on the page. The AI already sees it. Close the pane if you want to have a conversation without that context.

## AI as a Thinking Partner

Magus treats the AI as a collaborator, not just a tool. When the pane is open, you can ask the AI to:

- Write full pages from your notes. Just share your thoughts in the conversation and the AI will create a well-structured page with headings, lists, code blocks, and more.
- Append to existing pages. If you share information related to an existing page, the AI adds it to that page rather than creating a duplicate.
- Edit content with precision. The AI can find and replace specific text on a page without rewriting entire blocks.
- Add sources from URLs that auto-fetch and extract content.
- Connect related pages. The AI can link two pages together so they show up in each other's Related tabs.
- Search across all your brains to find the right place for new information.
- Route content to the right brain when you have multiple brains (Work, Personal, Research).

Everything the AI adds is attributed in the Activity log so you always know what it contributed and when.

**Best for:** research projects where you want to build understanding incrementally, not just get a one-off answer.

## Dropping Notes into Conversation

You do not need to open the Brain pane or use special commands to add information to your brain. Just share your notes, facts, or research naturally in the conversation. The AI decides where to put it.

### How It Works

When you share knowledge in a conversation, the AI:

1. Searches across your brains to find pages about the same topic.
2. If a matching page exists, appends your content there.
3. If nothing matches, creates a new page with a descriptive title.
4. Connects the new content to related pages automatically.
5. Tells you briefly what it did: which brain, which page, created or appended.

### Multiple Brains

If you have several brains (for example, a Work brain and a Personal brain), the AI routes content to the right one based on the topic. If it is unclear which brain to use, it asks you.

### Markdown Support

When the AI writes to your brain, it uses markdown to create properly structured content. Headings become heading blocks, code fences become code blocks, bullet lists become list items with correct nesting, and so on. You get clean, organized pages without manual formatting.

## Real-time Collaboration

Multiple team members can view and edit the same Brain page at the same time.

### Presence

When someone else has the same page open, you see a presence dot or avatar near the top of the pane. The viewer count badge also appears on the Brain entry in the sidebar.

### Live Updates

Changes from other users appear in the editor in real-time. You do not need to refresh. If you and a collaborator are both typing, your edits are merged automatically.

## Version History

Every edit to a block is tracked. If the AI or a collaborator makes a change you want to undo, you can restore a previous version.

The **Activity** tab shows a version count next to blocks that have been edited more than once. Version restore is available through the AI: ask the agent to restore a block to a previous state, and it will use the version history to find and apply the right snapshot.

## Page Operations

### Splitting a Page

If a page grows too large or starts covering multiple subtopics, the AI can split it. Ask something like "split the section about data sources into its own page" and the agent will move the relevant blocks to a new page while keeping the rest in place.

### Merging Pages

Two pages that cover the same ground can be merged. The AI moves all blocks from the source page into the target, preserving order, then removes the empty source. Ask "merge the Draft Notes page into the main Research page" to trigger this.

### Reorganizing Blocks

You can ask the AI to reorder blocks, change nesting levels, or restructure a page. The agent uses a dedicated tool to move multiple blocks in a single operation.

## Autonomous Agents

Custom agents with Brain access can work on your brains independently, even when you are not in a conversation.

### Granting Access

In your custom agent settings, grant the agent **editor** access to a specific brain. The agent will then include that brain's content in its regular heartbeat sweeps.

### What Autonomous Agents Can Do

During a heartbeat sweep, an agent with brain access can:

- Add new sources it discovers
- Write summaries of new information
- Create pages for emerging subtopics
- Organize and link related content

All autonomous contributions appear in the Activity tab with the agent's name, so you always know what changed and when.

## Organizing Your Brains

The AI helps with organization too. When you drop notes into a conversation, it automatically finds the right brain and page, or creates new ones as needed.

Keep each Brain focused on a single topic or project. Use pages within a Brain to break the topic into sections. For example, one page for background research, one for open questions, and one for conclusions.

Use `[[Page Name]]` links liberally to connect related pages. The **Related** tab shows you which pages reference each other, making it easy to navigate even large Brains.

When a project is complete, you can archive or delete the Brain from the Brains tab.
