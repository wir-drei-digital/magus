/**
 * BrainTiptapEditor LiveView hook (server-supplied ProseMirror JSON edition).
 *
 * The server is the single source of truth: it converts the page body
 * (markdown) to a ProseMirror JSON document (`Magus.Brain.Page`'s
 * `:prosemirror` calc) and ships it to the client. The hook never does any
 * markdown ↔ ProseMirror conversion of its own — there is no client-side
 * converter. Data flow:
 *
 *   server PM JSON ──▶ data-content ──▶ setContent(doc) ──▶ TipTap doc
 *                                                            │
 *                                                            ▼
 *                                     editor.getJSON() ──▶ debounced save
 *
 * The server uses optimistic locking on `Magus.Brain.Page.lock_version`. The
 * hook stores `_baseDoc` (the last server-known PM JSON) and `_lockVersion`
 * from the initial mount and sends `base_version` with every save so the
 * server can detect concurrent writes.
 *
 * Push contract (LiveView ⇄ hook):
 *
 *   server → hook:
 *     "brain:reload_body"        {prosemirror, lock_version, modified_at}
 *     "brain:conflict_overwrite" {current_prosemirror, current_version,
 *                                 conflicting_actor_id, your_unsaved_prosemirror}
 *     "brain:presence_diff"      {editors: [{user_id, name}, ...],
 *                                 current_user_id}
 *
 *   hook → server:
 *     "brain_editor_save"     {prosemirror, base_version}
 *     "brain_editor_presence" {state: "viewing" | "editing"}
 *     "brain_editor_dirty"    {}   (first keystroke after a save)
 *     "brain_editor_clean"    {}   (save acknowledged by server)
 */
import { Editor, Extension } from "@tiptap/core";
import { Plugin } from "prosemirror-state";
import StarterKit from "@tiptap/starter-kit";
import Placeholder from "@tiptap/extension-placeholder";
import Image from "@tiptap/extension-image";
import Link from "@tiptap/extension-link";
import Underline from "@tiptap/extension-underline";
import Typography from "@tiptap/extension-typography";
import Table from "@tiptap/extension-table";
import TableRow from "@tiptap/extension-table-row";
import TableCell from "@tiptap/extension-table-cell";
import TableHeader from "@tiptap/extension-table-header";
import Details from "@tiptap/extension-details";
import DetailsSummary from "@tiptap/extension-details-summary";
import DetailsContent from "@tiptap/extension-details-content";
import TaskList from "@tiptap/extension-task-list";
import TaskItem from "@tiptap/extension-task-item";
import {
  createSlashCommand,
  defaultCommands,
  DragHandle,
} from "tiptap-phoenix";
import { createBubbleMenu } from "../extensions/bubble_menu_with_extras";
import { EnhancedCodeBlock } from "../extensions/enhanced_code_block";
import { createPageLink } from "../extensions/page_link";
import {
  SourceBlock,
  FileBlock,
  MessageBlock,
  CalloutBlock,
  ImageBlock,
  PageRef,
  Tag,
} from "../extensions/brain_blocks";

const CHAT_SVG = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/></svg>`;

const SAVE_DEBOUNCE_MS = 800;
const IDLE_MS = 30_000;

// Empty ProseMirror document — mirrors `Magus.Markdown.ProseMirror.default_doc/0`
// and the server's fallback when a body fails to convert.
const DEFAULT_DOC = { type: "doc", content: [{ type: "paragraph" }] };

function getSelectionPayload(editor) {
  const { from, to } = editor.state.selection;
  const $from = editor.state.doc.resolve(from);
  const $to = editor.state.doc.resolve(to);
  const nodeStart = $from.start($from.depth);
  const nodeEnd = $to.end($to.depth);
  const nodeContext = editor.state.doc.textBetween(nodeStart, nodeEnd, "\n");
  return {
    from,
    to,
    text: editor.state.doc.textBetween(from, to, " "),
    node_context: nodeContext,
  };
}

/**
 * Hand off OS-file drops and clipboard-image pastes to the LiveView upload
 * pipeline (unchanged from the legacy hook — these still flow through
 * `phx-drop-target`).
 */
const FileDropAndPaste = Extension.create({
  name: "brainFileDropAndPaste",
  addProseMirrorPlugins() {
    return [
      new Plugin({
        props: {
          handleDOMEvents: {
            drop(view, event) {
              const magusPayload = event.dataTransfer?.getData(
                "application/x-magus-file",
              );
              if (magusPayload) {
                event.preventDefault();
                try {
                  const parsed = JSON.parse(magusPayload);
                  if (parsed && parsed.file_id) {
                    const wrapper = view.dom.closest("[data-page-id]");
                    const pageId = wrapper?.dataset?.pageId || null;
                    window.dispatchEvent(
                      new CustomEvent("phx:link-brain-file", {
                        detail: {
                          fileId: parsed.file_id,
                          workspaceId: parsed.workspace_id ?? null,
                          pageId,
                        },
                      }),
                    );
                  }
                } catch (e) {
                  console.warn("Brain editor: invalid magus-file payload", e);
                }
                return true;
              }

              if (
                event.dataTransfer &&
                event.dataTransfer.files &&
                event.dataTransfer.files.length > 0
              ) {
                event.preventDefault();
                return true;
              }
              return false;
            },
          },
          handlePaste(view, event) {
            const files = event.clipboardData && event.clipboardData.files;
            if (!files || files.length === 0) return false;
            event.preventDefault();
            const dropTarget =
              view.dom.closest("[phx-drop-target]") ||
              document.querySelector("[data-brain-pane] [phx-drop-target]");
            if (!dropTarget) return false;
            const dt = new DataTransfer();
            for (const f of files) dt.items.add(f);
            dropTarget.dispatchEvent(
              new DragEvent("drop", { bubbles: true, dataTransfer: dt }),
            );
            return true;
          },
        },
      }),
    ];
  },
});

const BrainTiptapEditor = {
  mounted() {
    const editorEl = this.el.querySelector("[data-tiptap-editor]");
    if (!editorEl) return;

    const scrollContainer = this.el.closest(".overflow-y-auto");
    if (scrollContainer) scrollContainer.scrollTop = 0;

    // ----- Mount data ------------------------------------------------------
    this._pageId = this.el.dataset.pageId;
    this._baseDoc = this._parseContent(this.el.dataset.content);
    this._lockVersion = parseInt(this.el.dataset.lockVersion || "0", 10);
    this._currentUserId = this.el.dataset.currentUserId || null;
    this._dirty = false;
    this._presenceEditing = false;
    this._suppressOnUpdate = false;
    this._saveDebounce = null;
    this._idleTimer = null;
    this._sourceInputCleanup = null;
    this._otherEditors = []; // [{user_id, name}]
    this._overlay = null;

    // Page list for the `[[` suggestion popup. Server pushes
    // `brain:update_pages` when the brain's page list changes.
    const pages = JSON.parse(this.el.dataset.pages || "[]");

    // Per-page file map keyed by file_id (image/file blocks render from this).
    // The server may keep injecting it; fall back to empty when absent.
    window.__brainFileMaps = window.__brainFileMaps || {};
    if (!window.__brainFileMaps[this._pageId]) {
      window.__brainFileMaps[this._pageId] = {};
    }

    // ----- Side-channel listeners (drag-drop, file-open, etc.) -------------
    this._setupDragDrop();

    this._openBrainFileHandler = (event) => {
      const { fileId, tabRole, pageId } = event.detail || {};
      if (!fileId) return;
      if (pageId && pageId !== this._pageId) return;
      this.pushEvent("open_brain_file", {
        file_id: fileId,
        tab_role: tabRole,
      });
    };
    window.addEventListener("phx:open-brain-file", this._openBrainFileHandler);

    this._linkBrainFileHandler = (event) => {
      const { fileId, pageId } = event.detail || {};
      if (!fileId) return;
      if (pageId && pageId !== this._pageId) return;
      this.pushEvent("link_brain_file", { file_id: fileId });
    };
    window.addEventListener("phx:link-brain-file", this._linkBrainFileHandler);

    this._pageRefClickHandler = (event) => {
      const { title } = event.detail || {};
      if (!title) return;
      // Only the focused editor (mouse target) should claim the event —
      // primary + companion brain panes both listen on window.
      const root = document.activeElement?.closest("[data-page-id]");
      if (root && root.dataset.pageId !== this._pageId) return;
      this.pushEvent("brain:open_page_ref", { title });
    };
    window.addEventListener(
      "phx:brain-page-ref-click",
      this._pageRefClickHandler,
    );

    // ----- Build the editor -----------------------------------------------
    const hook = this;
    const brainSlashCommands = [
      ...defaultCommands,
      {
        title: "Source",
        description: "Add a web source URL",
        icon: "&#128279;",
        command: ({ editor, range }) => {
          editor.chain().focus().deleteRange(range).run();
          hook._showSourceInput(editor);
        },
      },
      {
        title: "File",
        description: "Attach a file from your library",
        icon: "&#128206;",
        command: ({ editor, range }) => {
          editor.chain().focus().deleteRange(range).run();
          hook.pushEvent("open_brain_file_picker", {
            page_id: hook._pageId,
          });
        },
      },
      {
        title: "Mermaid Diagram",
        description: "Insert a mermaid diagram",
        icon: "&#9670;",
        command: ({ editor, range }) => {
          editor
            .chain()
            .focus()
            .deleteRange(range)
            .setCodeBlock({ language: "mermaid" })
            .insertContent("graph TD\n    A[Start] --> B[End]")
            .run();
        },
      },
      {
        title: "Math Formula",
        description: "Insert a LaTeX math formula",
        icon: "&#931;",
        command: ({ editor, range }) => {
          editor
            .chain()
            .focus()
            .deleteRange(range)
            .setCodeBlock({ language: "math" })
            .insertContent("E = mc^2")
            .run();
        },
      },
    ];

    const slashCommandExt = createSlashCommand(brainSlashCommands);
    const pageLinkExt = createPageLink(pages, {
      onPageRefClick: (title) =>
        this.pushEvent("brain:open_page_ref", { title }),
    });

    const bubbleMenuExt = createBubbleMenu({
      extras: [
        { type: "separator" },
        {
          type: "button",
          label: "Ask",
          icon: CHAT_SVG,
          event: "brain:ask_about_selection",
          getPayload: (editor) => getSelectionPayload(editor),
        },
      ],
      pushEvent: (event, payload) => this.pushEvent(event, payload),
    });

    this.editor = new Editor({
      element: editorEl,
      extensions: [
        StarterKit.configure({ codeBlock: false }),
        Placeholder.configure({
          placeholder: "Type '/' for commands, '[[' to link a page...",
        }),
        Image.configure({ inline: false, allowBase64: false }),
        Link.configure({ openOnClick: false, autolink: true }),
        Underline,
        Typography,
        Table.configure({ resizable: false }),
        TableRow,
        TableCell,
        TableHeader,
        Details.configure({ persist: true }),
        DetailsSummary,
        DetailsContent,
        TaskList,
        TaskItem.configure({ nested: true }),
        slashCommandExt,
        bubbleMenuExt,
        DragHandle,
        FileDropAndPaste,
        pageLinkExt,
        EnhancedCodeBlock,
        SourceBlock,
        FileBlock,
        MessageBlock,
        CalloutBlock,
        ImageBlock,
        PageRef,
        Tag,
      ],
      onUpdate: ({ editor }) => this._handleEditorUpdate(editor),
    });

    // Defer initial content so the schema is finalised before loading.
    // `setContent(..., false)` skips the onUpdate emit.
    this._setContentSilently(this._baseDoc);

    // ----- LiveView push handlers -----------------------------------------
    this.handleEvent("brain:reload_body", ({ prosemirror, lock_version }) => {
      this._baseDoc = prosemirror || DEFAULT_DOC;
      if (typeof lock_version === "number") this._lockVersion = lock_version;
      this._setContentSilently(this._baseDoc);
      this._setDirty(false);
    });

    this.handleEvent("brain:conflict_overwrite", (payload) => {
      this._showConflictToast(payload);
      const { current_prosemirror, current_version } = payload || {};
      this._baseDoc = current_prosemirror || DEFAULT_DOC;
      if (typeof current_version === "number") {
        this._lockVersion = current_version;
      }
      this._setContentSilently(this._baseDoc);
      this._setDirty(false);
    });

    this.handleEvent("brain:update_pages", ({ pages: newPages }) =>
      this._updatePages(newPages),
    );

    // File-status refresh: server sends the latest file map (file_id ->
    // summary) when a referenced file changes status. We swap the per-page
    // entry and re-render any imageBlock / fileBlock NodeViews by replacing
    // them with identical-attr copies (forces NodeView recompute).
    this.handleEvent("brain:file-map-updated", ({ file_map }) => {
      if (!this._pageId) return;
      window.__brainFileMaps[this._pageId] = file_map || {};
      this._refreshAttachmentNodeViews();
    });

    this.handleEvent("brain:presence_diff", (payload) =>
      this._handlePresenceDiff(payload),
    );
  },

  destroyed() {
    if (this._saveDebounce) clearTimeout(this._saveDebounce);
    if (this._idleTimer) clearTimeout(this._idleTimer);
    this._cleanupSourceInput();
    this._cleanupDragDrop();
    this._removeOverlay();

    if (this._openBrainFileHandler) {
      window.removeEventListener(
        "phx:open-brain-file",
        this._openBrainFileHandler,
      );
    }
    if (this._linkBrainFileHandler) {
      window.removeEventListener(
        "phx:link-brain-file",
        this._linkBrainFileHandler,
      );
    }
    if (this._pageRefClickHandler) {
      window.removeEventListener(
        "phx:brain-page-ref-click",
        this._pageRefClickHandler,
      );
    }
    if (this._pageId && window.__brainFileMaps) {
      delete window.__brainFileMaps[this._pageId];
    }
    if (this.editor) {
      this.editor.destroy();
      this.editor = null;
    }
  },

  // ===========================================================================
  // Editor update → debounced save + dirty/idle bookkeeping
  // ===========================================================================

  _handleEditorUpdate(editor) {
    if (this._suppressOnUpdate) return;

    // Two independent transitions on first-keystroke-after-X:
    //   1. dirty (was clean) — fires brain_editor_dirty
    //   2. editing (was idle/viewing) — fires brain_editor_presence
    // They commonly fire together (just after a save) but can drift:
    // user types, save fires (clean), user keeps typing (dirty again
    // without re-entering editing because they never went idle); or
    // user is mid-edit (dirty) goes idle (viewing) then types again
    // (back to editing without re-firing dirty).
    if (!this._dirty) this._setDirty(true);
    if (!this._presenceEditing) {
      this._presenceEditing = true;
      this.pushEvent("brain_editor_presence", { state: "editing" });
    }
    this._resetIdleTimer();

    if (this._saveDebounce) clearTimeout(this._saveDebounce);
    this._saveDebounce = setTimeout(() => {
      const prosemirror = editor.getJSON();
      this.pushEvent(
        "brain_editor_save",
        { prosemirror, base_version: this._lockVersion },
        (reply) => {
          // The server reply is one of:
          //   {ok: true, lock_version: N}      — save accepted
          //   {ok: false, reason: "conflict"}  — handled by brain:conflict_overwrite
          //   undefined                        — older server, treat as ok
          if (!reply || reply.ok) {
            this._baseDoc = prosemirror;
            if (reply && typeof reply.lock_version === "number") {
              this._lockVersion = reply.lock_version;
            } else {
              // Without an explicit version bump from the server we still
              // assume monotonic increment so subsequent saves don't keep
              // sending a stale base_version.
              this._lockVersion += 1;
            }
            this._setDirty(false);
          }
        },
      );
    }, SAVE_DEBOUNCE_MS);
  },

  _setDirty(dirty) {
    if (dirty === this._dirty) return;
    this._dirty = dirty;
    this.pushEvent(dirty ? "brain_editor_dirty" : "brain_editor_clean", {});
  },

  _resetIdleTimer() {
    if (this._idleTimer) clearTimeout(this._idleTimer);
    this._idleTimer = setTimeout(() => {
      this._presenceEditing = false;
      this.pushEvent("brain_editor_presence", { state: "viewing" });
    }, IDLE_MS);
  },

  // Parse the server-supplied PM JSON doc from `data-content`. Falls back to
  // an empty document if the attribute is missing or malformed so a bad
  // payload never leaves the editor blank-and-broken.
  _parseContent(raw) {
    if (!raw) return DEFAULT_DOC;
    try {
      return JSON.parse(raw);
    } catch (e) {
      console.warn("Brain editor: invalid data-content JSON", e);
      return DEFAULT_DOC;
    }
  },

  _setContentSilently(doc) {
    if (!this.editor) return;
    this._suppressOnUpdate = true;
    try {
      this.editor.commands.setContent(doc || DEFAULT_DOC, false);
    } finally {
      Promise.resolve().then(() => {
        this._suppressOnUpdate = false;
      });
    }
  },

  _refreshAttachmentNodeViews() {
    if (!this.editor || this.editor.isDestroyed) return;
    this._suppressOnUpdate = true;
    try {
      const targets = [];
      this.editor.state.doc.descendants((node, pos) => {
        if (node.type.name === "fileBlock" || node.type.name === "imageBlock") {
          targets.push({ pos, size: node.nodeSize, attrs: { ...node.attrs }, type: node.type.name });
        }
      });
      if (targets.length === 0) return;

      const { tr } = this.editor.state;
      for (let i = targets.length - 1; i >= 0; i--) {
        const t = targets[i];
        const replacement = this.editor.schema.nodeFromJSON({
          type: t.type,
          attrs: t.attrs,
        });
        tr.replaceWith(t.pos, t.pos + t.size, replacement);
      }
      tr.setMeta("addToHistory", false);
      this.editor.view.dispatch(tr);
    } finally {
      Promise.resolve().then(() => {
        this._suppressOnUpdate = false;
      });
    }
  },

  // ===========================================================================
  // Conflict toast
  // ===========================================================================

  _showConflictToast({ conflicting_actor_id, your_unsaved_prosemirror }) {
    // The "copy your draft" affordance needs text, not PM JSON. There is no
    // client-side markdown serializer anymore, so recover the user's draft as
    // plain text walked out of the unsaved ProseMirror document.
    const draftText = extractPlainText(your_unsaved_prosemirror);

    const wrapper = document.createElement("div");
    wrapper.className = "toast toast-top toast-end z-50";
    wrapper.setAttribute("role", "alert");

    const alert = document.createElement("div");
    alert.className =
      "alert alert-error w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap items-start";

    const actor = conflicting_actor_id
      ? `another editor (${escapeHtml(String(conflicting_actor_id))})`
      : "another editor";

    alert.innerHTML = `
      <div class="flex-1">
        <p class="font-semibold">Your unsaved edits were overwritten</p>
        <p class="text-sm">${actor} saved the page first. Your draft has been preserved so you can recover it.</p>
        <button
          type="button"
          data-copy-draft
          class="btn btn-xs btn-soft mt-2"
        >Copy your draft to clipboard</button>
      </div>
      <button type="button" data-dismiss class="btn btn-xs btn-ghost">Dismiss</button>
    `;

    wrapper.appendChild(alert);
    document.body.appendChild(wrapper);

    const cleanup = () => wrapper.remove();
    const autoTimer = setTimeout(cleanup, 20_000);

    alert.querySelector("[data-copy-draft]")?.addEventListener("click", async () => {
      try {
        await navigator.clipboard.writeText(draftText || "");
        const btn = alert.querySelector("[data-copy-draft]");
        if (btn) btn.textContent = "Copied!";
      } catch (e) {
        console.warn("Clipboard copy failed", e);
      }
    });
    alert.querySelector("[data-dismiss]")?.addEventListener("click", () => {
      clearTimeout(autoTimer);
      cleanup();
    });
  },

  // ===========================================================================
  // Per-page presence — edit lock overlay
  //
  // The server publishes `brain:presence_diff` with the full list of OTHER
  // users in `:editing` state. When that list is non-empty we render a
  // read-only overlay on top of the editor with a "Take over" button.
  // Clicking the button promotes this client to `:editing` (the server
  // demotes the previous editor after 30s of silence).
  // ===========================================================================

  _handlePresenceDiff({ editors, current_user_id }) {
    if (current_user_id) this._currentUserId = current_user_id;
    this._otherEditors = (editors || []).filter(
      (e) => e.user_id && e.user_id !== this._currentUserId,
    );
    if (this._otherEditors.length > 0) {
      this._renderOverlay();
    } else {
      this._removeOverlay();
    }
  },

  _renderOverlay() {
    if (this._overlay) {
      this._updateOverlayCopy();
      return;
    }
    const host = this.el.querySelector("[data-tiptap-editor]");
    if (!host) return;

    // Make the host a positioning context.
    const prevPosition = host.style.position;
    host.dataset._prevPosition = prevPosition || "";
    if (!prevPosition) host.style.position = "relative";

    // Lock the editor input.
    if (this.editor) this.editor.setEditable(false);

    const overlay = document.createElement("div");
    overlay.className =
      "absolute inset-0 z-10 bg-base-100/60 backdrop-blur-[1px] flex items-center justify-center cursor-not-allowed";
    overlay.setAttribute("data-brain-edit-lock", "");

    const card = document.createElement("div");
    card.className =
      "bg-base-100 border border-base-300 rounded-lg shadow-lg p-4 max-w-sm text-center";
    card.innerHTML = `
      <p class="text-sm font-medium text-base-content" data-overlay-message></p>
      <p class="text-xs text-base-content/60 mt-1">You can keep reading. The lock releases after 30 seconds of inactivity from them.</p>
      <button type="button" data-take-over class="btn btn-sm btn-primary mt-3">Take over editing</button>
    `;
    overlay.appendChild(card);
    host.appendChild(overlay);

    this._overlay = overlay;
    this._updateOverlayCopy();

    card.querySelector("[data-take-over]")?.addEventListener("click", () => {
      // Optimistically remove the overlay; server will rebroadcast presence.
      this._removeOverlay();
      this._presenceEditing = true;
      this.pushEvent("brain_editor_presence", { state: "editing" });
    });
  },

  _updateOverlayCopy() {
    if (!this._overlay) return;
    const msg = this._overlay.querySelector("[data-overlay-message]");
    if (!msg) return;
    const names = this._otherEditors
      .map((e) => e.name || `user ${e.user_id?.slice(0, 8) || ""}`)
      .filter(Boolean);
    const list =
      names.length === 1
        ? names[0]
        : names.length === 2
          ? `${names[0]} and ${names[1]}`
          : `${names.slice(0, -1).join(", ")} and ${names.slice(-1)}`;
    msg.textContent = `${list || "Someone"} is editing this page.`;
  },

  _removeOverlay() {
    if (!this._overlay) return;
    const host = this.el.querySelector("[data-tiptap-editor]");
    if (host && host.dataset._prevPosition !== undefined) {
      host.style.position = host.dataset._prevPosition || "";
      delete host.dataset._prevPosition;
    }
    this._overlay.remove();
    this._overlay = null;
    if (this.editor) this.editor.setEditable(true);
  },

  // ===========================================================================
  // Source URL Input (inline)
  // ===========================================================================

  _showSourceInput(editor) {
    this._cleanupSourceInput();

    const container = document.createElement("div");
    container.className =
      "flex items-center gap-2 px-2 py-1.5 bg-base-200/50 rounded-lg border border-base-300/50 my-2";

    const icon = document.createElement("span");
    icon.className = "text-base-content/40 text-sm flex-shrink-0";
    icon.textContent = "\u{1F517}";

    const input = document.createElement("input");
    input.type = "url";
    input.placeholder = "Enter source URL...";
    input.className =
      "flex-1 bg-transparent border-none outline-none text-sm text-base-content placeholder:text-base-content/30";

    const submitBtn = document.createElement("button");
    submitBtn.className = "btn btn-primary btn-xs px-2";
    submitBtn.textContent = "Add";

    const cancelBtn = document.createElement("button");
    cancelBtn.className = "btn btn-ghost btn-xs px-2";
    cancelBtn.textContent = "Cancel";

    container.append(icon, input, submitBtn, cancelBtn);

    const editorEl = this.el.querySelector("[data-tiptap-editor]");
    editorEl.parentNode.insertBefore(container, editorEl.nextSibling);

    const cleanup = () => {
      container.remove();
      this._sourceInputCleanup = null;
      editor.commands.focus();
    };

    const submit = () => {
      const url = input.value.trim();
      if (url) this.pushEvent("brain:add_source", { url });
      cleanup();
    };

    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        submit();
      }
      if (e.key === "Escape") {
        e.preventDefault();
        cleanup();
      }
    });
    submitBtn.addEventListener("click", submit);
    cancelBtn.addEventListener("click", cleanup);

    this._sourceInputCleanup = cleanup;
    input.focus();
  },

  _cleanupSourceInput() {
    if (this._sourceInputCleanup) {
      this._sourceInputCleanup();
      this._sourceInputCleanup = null;
    }
  },

  // ===========================================================================
  // Drag & Drop (message → editor)
  //
  // Inserts the message directly as a `messageBlock` atom node. On save the
  // server (`Magus.Brain.ProseMirrorProfile`) serializes it back to the
  // `[[msg:<id>|preview]]` markdown shape; on the next server-supplied load it
  // is lifted back into a `messageBlock` by the same profile.
  // ===========================================================================

  _setupDragDrop() {
    this._onDragOver = (e) => {
      if (e.dataTransfer.types.includes("application/x-brain-message")) {
        e.preventDefault();
        e.dataTransfer.dropEffect = "copy";
        this.el.classList.add("ring-2", "ring-primary/30");
      }
    };

    this._onDragLeave = () => {
      this.el.classList.remove("ring-2", "ring-primary/30");
    };

    this._onDrop = (e) => {
      if (!e.dataTransfer.types.includes("application/x-brain-message")) return;
      e.preventDefault();
      this.el.classList.remove("ring-2", "ring-primary/30");

      const raw = e.dataTransfer.getData("application/x-brain-message");
      if (!raw) return;

      let msg;
      try {
        msg = JSON.parse(raw);
      } catch (_err) {
        return;
      }

      if (this.editor) {
        const coords = this.editor.view.posAtCoords({
          left: e.clientX,
          top: e.clientY,
        });
        const pos = coords ? coords.pos : this.editor.state.doc.content.size;
        this.editor
          .chain()
          .focus()
          .insertContentAt(pos, {
            type: "messageBlock",
            attrs: {
              messageId: msg.messageId,
              conversationId: msg.conversationId,
              previewText: msg.text || "",
            },
          })
          .run();
      } else {
        this.pushEvent("add_message_to_brain", {
          "message-id": msg.messageId,
          "conversation-id": msg.conversationId,
          text: msg.text,
        });
      }
    };

    this.el.addEventListener("dragover", this._onDragOver);
    this.el.addEventListener("dragleave", this._onDragLeave);
    this.el.addEventListener("drop", this._onDrop);
  },

  _cleanupDragDrop() {
    if (this._onDragOver) {
      this.el.removeEventListener("dragover", this._onDragOver);
      this.el.removeEventListener("dragleave", this._onDragLeave);
      this.el.removeEventListener("drop", this._onDrop);
    }
  },

  // ===========================================================================
  // Page list updates (`[[` suggestion popup)
  // ===========================================================================

  _updatePages(newPages) {
    const pageLinkExt = this.editor?.extensionManager?.extensions?.find(
      (ext) => ext.name === "pageLink",
    );
    if (pageLinkExt) {
      newPages = Array.isArray(newPages) ? newPages : [];
      pageLinkExt.options.pages.length = 0;
      pageLinkExt.options.pages.push(...newPages);
      this.editor.commands.rebuildPageRefs?.();
    }
  },
};

function escapeHtml(str) {
  if (!str) return "";
  return String(str)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// Walk a ProseMirror JSON document and concatenate its text nodes, inserting a
// newline between top-level blocks. Best-effort recovery text for the conflict
// toast's clipboard copy (no markdown serializer is available client-side).
function extractPlainText(doc) {
  if (!doc || typeof doc !== "object") return "";
  const parts = [];
  const walk = (node) => {
    if (!node) return;
    if (typeof node.text === "string") parts.push(node.text);
    if (Array.isArray(node.content)) node.content.forEach(walk);
  };
  if (Array.isArray(doc.content)) {
    doc.content.forEach((block, i) => {
      if (i > 0) parts.push("\n");
      walk(block);
    });
  } else {
    walk(doc);
  }
  return parts.join("");
}

export default BrainTiptapEditor;
