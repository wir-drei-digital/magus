// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/magus";
import topbar from "../vendor/topbar";
import Sortable from "../vendor/sortable";
window.Sortable = Sortable;
import Chart from "../vendor/chart.js";
import { createTiptapHook, defaultCommands } from "tiptap-phoenix";
import { EnhancedCodeBlock } from "./extensions/enhanced_code_block";
import PdfViewer from "./pdf_viewer";
// Spreadsheet companion's Univer adapter is intentionally NOT imported
// here. It is built as a separate esbuild entry and lazy-loaded by the
// SpreadsheetCompanion's colocated hook the first time an .xlsx is
// opened, keeping ~18MB of Univer + SheetJS out of the eager bundle.
import ServiceCapture from "./service_capture";
import BrainTiptapEditor from "./hooks/brain_tiptap_editor";
import DraggableMessage from "./hooks/draggable_message";
import ResizablePanel from "./hooks/resizable_panel";
import {
  FilesDropTarget,
  FilesDragSource,
} from "./hooks/files_drop_target";

const SPARKLES_SVG = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z"/><path d="M20 3v4"/><path d="M22 5h-4"/></svg>`;
const CHAT_SVG = `<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M7.9 20A9 9 0 1 0 4 16.1L2 22Z"/></svg>`;

function getSelectionPayload(editor) {
  const { from, to } = editor.state.selection;
  const $from = editor.state.doc.resolve(from);
  const $to = editor.state.doc.resolve(to);

  // Extract the full block node(s) containing the selection for LLM context
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

const TiptapEditor = createTiptapHook({
  // EnhancedCodeBlock extends CodeBlockLowlight to add mermaid/math
  // previews. Passing it via `extensions` tells the upstream hook to
  // skip its built-in CodeBlockLowlight, avoiding a duplicate-keyed
  // ProseMirror plugin that crashes the editor on construction.
  extensions: [EnhancedCodeBlock],
  slashCommands: [
    ...defaultCommands,
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
  ],
  bubbleMenuExtras: [
    { type: "separator" },
    {
      type: "input",
      label: "Refine",
      icon: SPARKLES_SVG,
      placeholder: "Improve this text...",
      event: "draft:refine_selection",
      getPayload: (editor, instruction) => ({
        ...getSelectionPayload(editor),
        instruction,
      }),
    },
    {
      type: "button",
      label: "Ask",
      icon: CHAT_SVG,
      event: "draft:ask_about_selection",
      getPayload: (editor) => getSelectionPayload(editor),
    },
  ],
});

// Password visibility toggle for auth forms
// Uses MutationObserver to survive LiveView DOM patches
const PasswordToggle = {
  init() {
    this.enhance();
    // Observe DOM for new/replaced password inputs (LiveView patches, navigations)
    new MutationObserver(() => this.enhance()).observe(document.body, {
      childList: true,
      subtree: true,
    });
  },

  enhance() {
    document.querySelectorAll('input[type="password"]').forEach((input) => {
      if (input.parentElement?.classList.contains("pw-input-wrapper")) return;

      // Wrap the input in a relative container so the toggle aligns to the input, not the field wrapper
      const innerWrapper = document.createElement("div");
      innerWrapper.className = "pw-input-wrapper relative";
      input.parentElement.insertBefore(innerWrapper, input);
      innerWrapper.appendChild(input);

      const btn = document.createElement("button");
      btn.type = "button";
      btn.className =
        "pw-toggle-btn absolute right-2 top-1/2 -translate-y-1/2 text-base-content/40 hover:text-base-content/70 transition-colors cursor-pointer";
      btn.setAttribute("tabindex", "-1");
      btn.setAttribute("aria-label", "Show password");
      btn.innerHTML = `
          <svg class="pw-eye-open size-5" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" d="M2.036 12.322a1.012 1.012 0 0 1 0-.639C3.423 7.51 7.36 4.5 12 4.5c4.64 0 8.573 3.007 9.963 7.178.07.207.07.431 0 .639C20.577 16.49 16.64 19.5 12 19.5c-4.64 0-8.573-3.007-9.963-7.178Z" />
            <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
          </svg>
          <svg class="pw-eye-closed size-5 hidden" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24" stroke-width="1.5" stroke="currentColor">
            <path stroke-linecap="round" stroke-linejoin="round" d="M3.98 8.223A10.477 10.477 0 0 0 1.934 12c1.292 4.338 5.31 7.5 10.066 7.5.993 0 1.953-.138 2.863-.395M6.228 6.228A10.451 10.451 0 0 1 12 4.5c4.756 0 8.773 3.162 10.065 7.498a10.522 10.522 0 0 1-4.293 5.774M6.228 6.228 3 3m3.228 3.228 3.65 3.65m7.894 7.894L21 21m-3.228-3.228-3.65-3.65m0 0a3 3 0 1 0-4.243-4.243m4.242 4.242L9.88 9.88" />
          </svg>
        `;

      btn.addEventListener("click", (e) => {
        e.preventDefault();
        const isPassword = input.type === "password";
        input.type = isPassword ? "text" : "password";
        btn.setAttribute(
          "aria-label",
          isPassword ? "Hide password" : "Show password",
        );
        btn.querySelector(".pw-eye-open").classList.toggle("hidden");
        btn.querySelector(".pw-eye-closed").classList.toggle("hidden");
      });

      // Add right padding to input so text doesn't overlap the toggle
      input.style.paddingRight = "2.5rem";
      innerWrapper.appendChild(btn);
    });
  },
};

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => PasswordToggle.init());
} else {
  PasswordToggle.init();
}

// Global floating search bar
const GlobalSearch = {
  overlay: null,
  input: null,
  isOpen: false,

  init() {
    this.createOverlay();
    this.bindEvents();
  },

  createOverlay() {
    // Create overlay container
    this.overlay = document.createElement("div");
    this.overlay.id = "global-search-overlay";
    this.overlay.className =
      "fixed inset-0 z-[9999] hidden items-start justify-center pt-[15vh] bg-base-100/80 backdrop-blur-sm";
    this.overlay.innerHTML = `
      <div class="w-full max-w-2xl mx-4 bg-base-200 rounded-xl shadow-2xl border border-base-300 overflow-hidden">
        <div class="flex items-center gap-3 px-4 py-3 border-b border-base-300">
          <svg class="w-5 h-5 text-base-content/40 shrink-0" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"></path>
          </svg>
          <input
            id="global-search-input"
            type="text"
            placeholder="Search messages, conversations, blocks, files..."
            class="flex-1 bg-transparent text-base-content placeholder:text-base-content/40 text-lg outline-none"
            autocomplete="off"
          />
          <kbd class="px-2 py-1 text-xs bg-base-300 text-base-content/60 rounded font-mono">Esc</kbd>
        </div>
        <div class="px-4 py-3 text-sm text-base-content/50 flex items-center gap-4">
          <span class="flex items-center gap-1.5">
            <kbd class="px-1.5 py-0.5 bg-base-300 rounded text-xs font-mono">Enter</kbd>
            to search
          </span>
          <span class="flex items-center gap-1.5">
            <kbd class="px-1.5 py-0.5 bg-base-300 rounded text-xs font-mono">Esc</kbd>
            to close
          </span>
        </div>
      </div>
    `;

    document.body.appendChild(this.overlay);
    this.input = document.getElementById("global-search-input");
  },

  bindEvents() {
    // Global keyboard shortcut
    document.addEventListener("keydown", (e) => {
      // Cmd/Ctrl + K to open search
      if ((e.metaKey || e.ctrlKey) && e.key === "k") {
        e.preventDefault();
        this.open();
      }

      // Escape to close
      if (e.key === "Escape" && this.isOpen) {
        e.preventDefault();
        this.close();
      }
    });

    // Close on overlay click
    this.overlay.addEventListener("click", (e) => {
      if (e.target === this.overlay) {
        this.close();
      }
    });

    // Handle input
    this.input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") {
        e.preventDefault();
        this.submit();
      }
    });
  },

  open() {
    if (this.isOpen) return;
    this.isOpen = true;
    this.overlay.classList.remove("hidden");
    this.overlay.classList.add("flex");
    this.input.value = "";
    this.input.focus();
  },

  close() {
    if (!this.isOpen) return;
    this.isOpen = false;
    this.overlay.classList.add("hidden");
    this.overlay.classList.remove("flex");
    this.input.value = "";
  },

  submit() {
    const query = this.input.value.trim();
    if (query.length >= 2) {
      window.location.href = `/search?q=${encodeURIComponent(query)}`;
    } else if (query.length === 0) {
      window.location.href = "/search";
    }
    this.close();
  },
};

// Initialize global search when DOM is ready and expose on window
if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", () => GlobalSearch.init());
} else {
  GlobalSearch.init();
}
window.GlobalSearch = GlobalSearch;

// Global search hook (for LiveView pages that want more control)
const GlobalSearchHook = {
  GlobalSearch: {
    mounted() {
      // The global search bar handles Cmd/Ctrl+K
    },
  },
};

// Detect touch devices to avoid keyboard popping up unexpectedly.
// Uses coarse pointer media query (phones/tablets) with ontouchstart fallback.
function isTouchDevice() {
  return (
    window.matchMedia("(pointer: coarse)").matches ||
    "ontouchstart" in window
  );
}

// Brain drag-and-drop hooks
const BrainHooks = {
  // Hook for draggable prompts in the sidebar
  DraggablePrompts: {
    mounted() {
      this.el.querySelectorAll('[draggable="true"]').forEach((el) => {
        el.addEventListener("dragstart", (e) => {
          e.dataTransfer.setData(
            "application/json",
            JSON.stringify({
              type: "prompt",
              id: el.dataset.promptId,
              promptType: el.dataset.promptType,
            }),
          );
          el.classList.add("opacity-50");
        });
        el.addEventListener("dragend", (e) => {
          el.classList.remove("opacity-50");
        });
      });
    },
    updated() {
      this.mounted();
    },
  },

  // Hook for the drop zone (chat input area)
  DropZone: {
    mounted() {
      this.el.addEventListener("dragover", (e) => {
        e.preventDefault();
        this.el.classList.add("bg-base-300/50");
      });

      this.el.addEventListener("dragleave", (e) => {
        this.el.classList.remove("bg-base-300/50");
      });

      this.el.addEventListener("drop", (e) => {
        e.preventDefault();
        this.el.classList.remove("bg-base-300/50");

        const raw = e.dataTransfer.getData("application/json");
        if (!raw) return;

        try {
          const data = JSON.parse(raw);
          if (data.type === "prompt") {
            if (data.promptType === "system") {
              // System prompts can be activated
              this.pushEvent("activate_system_prompt_by_id", {
                prompt_id: data.id,
              });
            } else {
              // User prompts - insert content into chat input
              this.pushEvent("insert_prompt_content", { prompt_id: data.id });
            }
          } else if (data.type === "resource") {
            this.pushEvent("add_resource_to_context", {
              resource_id: data.id,
              resource_name: data.name,
            });
          } else if (data.type === "file") {
            // File dragged from the workbench Files sidebar / quick access.
            // The conversation view loads the file and pushes it onto its
            // `context_resources` so it gets attached on the next message.
            this.pushEvent("add_file_to_context", { file_id: data.id });
          }
        } catch (_err) {
          // Ignore non-JSON drops (e.g. brain message drags)
        }
      });
    },
  },

  // Hook to focus message input on demand
  FocusMessageInput: {
    mounted() {
      this.handleEvent("focus_message_input", () => {
        if (isTouchDevice()) return;
        const textarea = this.el.querySelector("textarea");
        if (textarea) {
          textarea.focus();
        }
      });
    },
  },

  // Hook for chat textarea: Enter to submit, Shift+Enter for newline
  ChatTextarea: {
    mounted() {
      const conversationId = this.el.dataset.conversationId || "new";
      const storageKey = `magus_draft_${conversationId}`;

      // Auto-grow function - stored on this for access in updated()
      this.autoGrow = () => {
        // Save scroll position before resizing — setting height to "auto"
        // momentarily collapses the textarea which causes the browser to
        // scroll the page on every keystroke (see GitHub issue #11).
        const prevScrollY = window.scrollY;
        this.el.style.height = "auto";
        this.el.style.height = Math.min(this.el.scrollHeight, 500) + "px";
        if (window.scrollY !== prevScrollY) {
          window.scrollTo(0, prevScrollY);
        }
        updateHighlight();
      };
      const autoGrow = this.autoGrow;

      // --- @mention highlight backdrop ---
      // A div behind the textarea that mirrors text with <mark> around @mentions
      const wrapper = this.el.parentElement;
      wrapper.style.position = "relative";

      const backdrop = document.createElement("div");
      backdrop.className = "mention-highlight-backdrop";
      backdrop.setAttribute("aria-hidden", "true");
      wrapper.insertBefore(backdrop, this.el);

      // Make textarea background transparent so highlights show through
      this.el.style.background = "transparent";
      this.el.style.position = "relative";
      this.el.style.caretColor = "currentColor";

      const mentionHighlightRegex = /(?:^|\s)(@[a-z0-9][a-z0-9-]*)/g;

      const updateHighlight = () => {
        const text = this.el.value;
        // Escape HTML, then wrap @mentions with <mark>
        const escaped = text
          .replace(/&/g, "&amp;")
          .replace(/</g, "&lt;")
          .replace(/>/g, "&gt;");
        const highlighted = escaped.replace(
          mentionHighlightRegex,
          (match, mention) => {
            const prefix = match.slice(0, match.length - mention.length);
            return `${prefix}<mark class="mention-hl">${mention}</mark>`;
          },
        );
        // Trailing newline fix: browsers collapse trailing newlines in divs
        backdrop.innerHTML = highlighted + "\n";
        backdrop.scrollTop = this.el.scrollTop;
        backdrop.scrollLeft = this.el.scrollLeft;
      };

      this.el.addEventListener("scroll", () => {
        backdrop.scrollTop = this.el.scrollTop;
        backdrop.scrollLeft = this.el.scrollLeft;
      });

      // @mention state
      this._mentionActive = false;
      this._mentionStart = -1; // cursor position of the '@' character

      // Extract @mention query from cursor position
      const getMentionQuery = () => {
        const cursor = this.el.selectionStart;
        const text = this.el.value;
        // Walk backwards from cursor to find '@'
        let i = cursor - 1;
        while (i >= 0) {
          const ch = text[i];
          if (ch === "@") {
            // '@' must be at start of input or preceded by whitespace
            // This prevents matching email addresses (user@domain)
            if (i === 0 || /\s/.test(text[i - 1])) {
              const query = text.slice(i + 1, cursor);
              // Only match lowercase alphanumeric + hyphens (valid handle chars)
              if (/^[a-z0-9][a-z0-9-]*$/.test(query) || query === "") {
                return { start: i, query };
              }
            }
            return null;
          }
          // Stop at whitespace — no multi-word mentions
          if (/\s/.test(ch)) return null;
          i--;
        }
        return null;
      };

      const checkMention = () => {
        const target = this.el.dataset.target;
        if (!target) return;
        const mention = getMentionQuery();
        if (mention) {
          this._mentionActive = true;
          this._mentionStart = mention.start;
          this.pushEventTo(target, "mention_search", {
            query: mention.query,
          });
        } else if (this._mentionActive) {
          this._mentionActive = false;
          this._mentionStart = -1;
          this.pushEventTo(target, "mention_close", {});
        }
      };

      // If we have a real conversation ID, clear the "new" draft
      // This handles the case where a new conversation was just created
      if (conversationId !== "new") {
        localStorage.removeItem("magus_draft_new");
      }

      // Restore saved draft from localStorage
      const savedDraft = localStorage.getItem(storageKey);
      if (savedDraft && !this.el.value) {
        this.el.value = savedDraft;
        const target = this.el.dataset.target;
        if (target) {
          this.pushEventTo(target, "sync_text", { value: savedDraft });
        }
        // Grow to fit restored draft
        autoGrow();
      }

      // Auto-focus on mount for desktop only — avoids opening the
      // on-screen keyboard unexpectedly on mobile/tablet.
      if (!isTouchDevice()) {
        this.el.focus();
      }

      this.el.addEventListener("keydown", (e) => {
        // When mention dropdown is active, intercept navigation keys
        if (this._mentionActive) {
          const target = this.el.dataset.target;
          if (e.key === "ArrowUp") {
            e.preventDefault();
            if (target)
              this.pushEventTo(target, "mention_navigate", {
                direction: "up",
              });
            return;
          }
          if (e.key === "ArrowDown") {
            e.preventDefault();
            if (target)
              this.pushEventTo(target, "mention_navigate", {
                direction: "down",
              });
            return;
          }
          if (e.key === "Enter" || e.key === "Tab") {
            e.preventDefault();
            // Select current highlighted item — server will push mention_insert
            if (target)
              this.pushEventTo(target, "mention_select", { handle: "" });
            return;
          }
          if (e.key === "Escape") {
            e.preventDefault();
            this._mentionActive = false;
            this._mentionStart = -1;
            if (target) this.pushEventTo(target, "mention_close", {});
            return;
          }
        }

        if (e.key === "Enter" && !e.shiftKey) {
          e.preventDefault();
          // Find and submit the parent form, but only if submit button is enabled
          const form = this.el.closest("form");
          if (form) {
            const submitBtn = form.querySelector('button[type="submit"]');
            if (submitBtn && submitBtn.disabled) return;
            form.dispatchEvent(
              new Event("submit", { bubbles: true, cancelable: true }),
            );
          }
        }
      });

      // Sync text value to server on every input and save to localStorage
      this.el.addEventListener("input", () => {
        const target = this.el.dataset.target;
        if (target) {
          this.pushEventTo(target, "sync_text", { value: this.el.value });
        }
        // Save to localStorage
        if (this.el.value) {
          localStorage.setItem(storageKey, this.el.value);
        } else {
          localStorage.removeItem(storageKey);
        }
        // Auto-grow on input
        autoGrow();
        // Update mention highlights
        updateHighlight();
        // Check for @mention
        checkMention();
      });

      // Auto-grow on paste, and handle file paste (screenshots, copied images)
      this.el.addEventListener("paste", (e) => {
        const items = e.clipboardData?.items;
        if (items) {
          const files = [];
          for (const item of items) {
            if (item.kind === "file") {
              const file = item.getAsFile();
              if (file) files.push(file);
            }
          }
          if (files.length > 0) {
            const form = this.el.closest("form");
            const fileInput = form?.querySelector("input[type='file']");
            if (fileInput) {
              const dt = new DataTransfer();
              files.forEach((f) => dt.items.add(f));
              fileInput.files = dt.files;
              fileInput.dispatchEvent(new Event("change", { bubbles: true }));
            }
            e.preventDefault();
            return;
          }
        }
        setTimeout(autoGrow, 0);
      });

      this.handleEvent("clear_message_input", ({target} = {}) => {
        // If a target is specified, only clear the matching textarea
        if (target && target !== this.el.id) return;
        this.el.value = "";
        // Clear localStorage draft
        localStorage.removeItem(storageKey);
        // Reset height
        this.el.style.height = "auto";
        this._mentionActive = false;
        this._mentionStart = -1;
        updateHighlight();
        // On touch devices, blur to dismiss keyboard so the user can read the response.
        // On desktop, refocus so the user can keep typing immediately.
        if (isTouchDevice()) {
          this.el.blur();
        } else {
          this.el.focus();
        }
      });

      // Handle inserting prompt content
      this.handleEvent("insert_text", ({ text, mode }) => {
        if (mode == "replace") {
          // Replace mode: clear input and set new text
          this.el.value = text;
          this.el.setSelectionRange(text.length, text.length);
        } else if (mode == "prepend") {
          // Prepend mode: insert at the beginning
          this.el.value = text + " " + this.el.value;
          this.el.setSelectionRange(this.el.value.length, this.el.value.length);
        } else {
          // Insert at cursor position or append
          const start = this.el.selectionStart;
          const end = this.el.selectionEnd;
          const currentValue = this.el.value;

          // If there's already content, add a newline before the inserted text
          const prefix = currentValue.slice(0, start);
          const suffix = currentValue.slice(end);
          const separator = prefix && !prefix.endsWith("\n") ? "\n" : "";

          this.el.value = prefix + separator + text + suffix;

          // Update cursor position
          const newPosition = start + separator.length + text.length;
          this.el.setSelectionRange(newPosition, newPosition);
        }

        // Save to localStorage
        if (this.el.value) {
          localStorage.setItem(storageKey, this.el.value);
        }

        // Sync to server
        const target = this.el.dataset.target;
        if (target) {
          this.pushEventTo(target, "sync_text", { value: this.el.value });
        }

        // Auto-grow after insert
        autoGrow();

        if (!isTouchDevice()) {
          this.el.focus();
        }
      });

      // Handle @mention selection — replace @query with @handle
      this.handleEvent("mention_insert", ({ handle }) => {
        if (this._mentionStart >= 0) {
          const before = this.el.value.slice(0, this._mentionStart);
          const after = this.el.value.slice(this.el.selectionStart);
          const insertion = `@${handle} `;
          this.el.value = before + insertion + after;
          const newCursor = before.length + insertion.length;
          this.el.setSelectionRange(newCursor, newCursor);

          // Save to localStorage
          if (this.el.value) {
            localStorage.setItem(storageKey, this.el.value);
          }

          // Sync to server
          const target = this.el.dataset.target;
          if (target) {
            this.pushEventTo(target, "sync_text", {
              value: this.el.value,
            });
          }

          autoGrow();
          updateHighlight();
          if (!isTouchDevice()) {
            this.el.focus();
          }
        }
        this._mentionActive = false;
        this._mentionStart = -1;
      });
    },
    beforeUpdate() {
      // Store current height and value before LiveView re-renders
      this._savedHeight = this.el.style.height;
      this._savedValue = this.el.value;
    },
    updated() {
      // Restore height after LiveView re-renders to prevent flickering
      if (this._savedHeight) {
        this.el.style.height = this._savedHeight;
      }
      // Only recalculate height if content actually changed (e.g., cleared input)
      if (this.el.value !== this._savedValue) {
        this.autoGrow();
      }
    },
  },

  // Hook for @mention dropdown — scrolls active item into view
  MentionDropdown: {
    updated() {
      const active = this.el.querySelector("[data-active='true']");
      if (active) {
        active.scrollIntoView({ block: "nearest" });
      }
    },
  },

  // Hook for draggable resources in the memory sidebar
  DraggableResources: {
    mounted() {
      this.el.querySelectorAll('[draggable="true"]').forEach((el) => {
        el.addEventListener("dragstart", (e) => {
          e.dataTransfer.setData(
            "application/json",
            JSON.stringify({
              type: "resource",
              id: el.dataset.resourceId,
              name: el.dataset.resourceName,
              resourceType: el.dataset.resourceType,
            }),
          );
          el.classList.add("opacity-50");
        });
        el.addEventListener("dragend", (e) => {
          el.classList.remove("opacity-50");
        });
      });
    },
    updated() {
      this.mounted();
    },
  },

  // Hook for chat input drop zone visual feedback
  ChatDropZone: {
    mounted() {
      const overlay = this.el.querySelector("#drop-overlay");

      this.el.addEventListener("dragenter", (e) => {
        // Only show overlay for file drops, not for block/stack drops
        if (e.dataTransfer.types.includes("Files")) {
          overlay?.classList.remove("hidden");
        }
      });

      this.el.addEventListener("dragleave", (e) => {
        // Only hide if leaving the drop zone entirely
        if (!this.el.contains(e.relatedTarget)) {
          overlay?.classList.add("hidden");
        }
      });

      this.el.addEventListener("drop", (e) => {
        overlay?.classList.add("hidden");
      });
    },
  },

  DraggableConversation: {
    mounted() {
      this.el.addEventListener("dragstart", (e) => {
        e.dataTransfer.setData(
          "application/json",
          JSON.stringify({
            type: "conversation",
            id: this.el.dataset.conversationId,
            section: this.el.dataset.section || "personal",
            folderId: this.el.dataset.folderId || "",
          }),
        );
        this.el.classList.add("opacity-50");
      });
      this.el.addEventListener("dragend", () => {
        this.el.classList.remove("opacity-50");
      });
    },
  },

  DraggableFolder: {
    mounted() {
      this.el.addEventListener("dragstart", (e) => {
        e.stopPropagation();
        e.dataTransfer.setData(
          "application/json",
          JSON.stringify({
            type: "folder",
            id: this.el.dataset.folderId,
            section: this.el.dataset.section || "personal",
          }),
        );
        this.el.classList.add("opacity-50");
      });
      this.el.addEventListener("dragend", () => {
        this.el.classList.remove("opacity-50");
      });
    },
  },

  // File rows in the workbench Files sidebar. Sets a dedicated
  // "application/x-magus-file" payload (alongside the conversation-shaped
  // JSON for legacy drop targets) so the brain editor can recognise an
  // existing-file drop and create a file block without re-uploading.
  DraggableFile: {
    mounted() {
      this.el.addEventListener("dragstart", (e) => {
        const fileId =
          this.el.dataset.fileId || this.el.dataset.resourceId || "";
        const name = this.el.dataset.fileName || "";
        const workspaceId = this.el.dataset.fileWorkspaceId || null;

        e.dataTransfer.effectAllowed = "copy";
        e.dataTransfer.setData(
          "application/x-magus-file",
          JSON.stringify({
            file_id: fileId,
            name,
            workspace_id: workspaceId,
          }),
        );
        // Keep a JSON conversation-shaped payload too so existing
        // file-tree drop targets (e.g. folder reorder) still work as
        // before. They key off `type === "file"`.
        e.dataTransfer.setData(
          "application/json",
          JSON.stringify({
            type: "file",
            id: fileId,
            section: this.el.dataset.section || "personal",
          }),
        );
        this.el.classList.add("opacity-50");
      });
      this.el.addEventListener("dragend", () => {
        this.el.classList.remove("opacity-50");
      });
    },
  },

  FolderDropZone: {
    mounted() {
      this._header = this.el.querySelector(":scope > [data-folder-header]");
      this._dragTimer = null;

      const setAccept = () => {
        this._header?.classList.add("outline", "outline-1", "outline-wb-accent", "rounded-md");
        this.el.classList.add("bg-wb-hover/40");
      };
      const setReject = () => {
        this._header?.classList.add("outline", "outline-1", "outline-error/60", "cursor-not-allowed");
      };
      const clear = () => {
        this._header?.classList.remove(
          "outline", "outline-1",
          "outline-wb-accent", "outline-error/60",
          "rounded-md", "cursor-not-allowed",
        );
        this.el.classList.remove("bg-wb-hover/40");
      };

      const validate = (data) => {
        const sourceSection = data.section || "personal";
        const targetSection = this.el.dataset.section || "personal";
        if (sourceSection !== targetSection) return { ok: false, reason: "section" };

        if (data.type === "folder") {
          let node = this.el;
          while (node) {
            if (node.dataset && node.dataset.folderId === data.id) {
              return { ok: false, reason: "cycle" };
            }
            node = node.parentElement?.closest("[data-folder-id]") || null;
          }
        }
        return { ok: true };
      };

      const pushMove = (eventName, payload) => {
        if (this.el.getAttribute("phx-target")) {
          this.pushEventTo(this.el, eventName, payload);
        } else {
          this.pushEvent(eventName, payload);
        }
      };

      this.el.addEventListener("dragover", (e) => {
        e.preventDefault();
        e.stopPropagation();
        setAccept();
        clearTimeout(this._dragTimer);
        this._dragTimer = setTimeout(clear, 150);
      });

      this.el.addEventListener("dragleave", (e) => {
        e.stopPropagation();
        if (!this.el.contains(e.relatedTarget)) {
          clearTimeout(this._dragTimer);
          clear();
        }
      });

      this.el.addEventListener("drop", (e) => {
        e.preventDefault();
        e.stopPropagation();
        clearTimeout(this._dragTimer);
        clear();

        const raw = e.dataTransfer.getData("application/json");
        if (!raw) return;

        let data;
        try {
          data = JSON.parse(raw);
        } catch (_err) {
          return;
        }

        const check = validate(data);
        if (!check.ok) {
          setReject();
          setTimeout(clear, 250);
          return;
        }

        const folderId = this.el.dataset.folderId || "";
        const section = this.el.dataset.section || "personal";

        if (data.type === "conversation") {
          pushMove("move_conversation", {
            conversation_id: data.id,
            folder_id: folderId,
            section: section,
          });
        } else if (data.type === "folder" && data.id !== folderId) {
          pushMove("move_folder", {
            folder_id: data.id,
            parent_id: folderId,
            section: section,
          });
        }
      });
    },
    destroyed() {
      clearTimeout(this._dragTimer);
    },
  },

  DroppableFolder: {
    mounted() {
      this._dragTimer = null;

      const setAccept = () => this.el.classList.add("bg-wb-hover/40");
      const setReject = () => this.el.classList.add("outline", "outline-1", "outline-error/60");
      const clear = () => {
        this.el.classList.remove(
          "bg-wb-hover/40", "outline", "outline-1", "outline-error/60",
        );
      };

      const validate = (data) => {
        const sourceSection = data.section || "personal";
        const targetSection = this.el.dataset.section || "personal";
        if (sourceSection !== targetSection) return { ok: false };
        return { ok: true };
      };

      const pushMove = (eventName, payload) => {
        if (this.el.getAttribute("phx-target")) {
          this.pushEventTo(this.el, eventName, payload);
        } else {
          this.pushEvent(eventName, payload);
        }
      };

      this.el.addEventListener("dragover", (e) => {
        e.preventDefault();
        setAccept();
        clearTimeout(this._dragTimer);
        this._dragTimer = setTimeout(clear, 150);
      });

      this.el.addEventListener("dragleave", (e) => {
        if (!this.el.contains(e.relatedTarget)) {
          clearTimeout(this._dragTimer);
          clear();
        }
      });

      this.el.addEventListener("drop", (e) => {
        e.preventDefault();
        clearTimeout(this._dragTimer);
        clear();

        const raw = e.dataTransfer.getData("application/json");
        if (!raw) return;

        let data;
        try {
          data = JSON.parse(raw);
        } catch (_err) {
          return;
        }

        const check = validate(data);
        if (!check.ok) {
          setReject();
          setTimeout(clear, 250);
          return;
        }

        const folderId = this.el.dataset.folderId || "";
        const section = this.el.dataset.section || "personal";

        if (data.type === "conversation") {
          pushMove("move_conversation", {
            conversation_id: data.id,
            folder_id: folderId,
            section: section,
          });
        } else if (data.type === "folder" && data.id !== folderId) {
          pushMove("move_folder", {
            folder_id: data.id,
            parent_id: folderId,
            section: section,
          });
        }
      });
    },
    destroyed() {
      clearTimeout(this._dragTimer);
    },
  },
};

// Hook for auto-scrolling content within an element (e.g., streaming thinking)
// Respects user scroll position - only auto-scrolls if user hasn't scrolled up
const AutoScrollContentHook = {
  AutoScrollContent: {
    mounted() {
      this.userScrolledUp = false;
      const threshold = 0;

      // Track if user has scrolled up
      this.el.addEventListener("scroll", () => {
        const { scrollTop, scrollHeight, clientHeight } = this.el;
        this.userScrolledUp =
          scrollTop + clientHeight < scrollHeight - threshold;
      });

      // Initial scroll to bottom
      this.scrollToBottom();
    },
    updated() {
      // Auto-scroll on update if user hasn't scrolled up
      if (!this.userScrolledUp) {
        this.scrollToBottom();
      }
    },
    scrollToBottom() {
      requestAnimationFrame(() => {
        this.el.scrollTop = this.el.scrollHeight;
      });
    },
  },
};

// Hook for auto-scrolling to bottom of chat
// Uses wheel/touch events to detect user scroll intent (these never fire from
// programmatic scrollTo), so there's zero fighting with auto-scroll.
const AutoScrollHook = {
  AutoScroll: {
    mounted() {
      this.scrollUpIntent = false;
      this.serverScrolledUp = false;
      this.autoscrollEnabled = this.el.dataset.autoscrollEnabled !== "false";
      const reengageThreshold = 20;
      const scrollUpThreshold = 100;

      // Detect user scrolling up via wheel (desktop) - only sets local intent
      this.wheelHandler = (e) => {
        if (e.deltaY < 0) {
          this.scrollUpIntent = true;
        }
      };
      window.addEventListener("wheel", this.wheelHandler, { passive: true });

      // Detect user scrolling up via touch (mobile) - only sets local intent
      this.touchStartY = null;
      this.touchStartHandler = (e) => {
        this.touchStartY = e.touches[0].clientY;
      };
      this.touchMoveHandler = (e) => {
        if (
          this.touchStartY !== null &&
          e.touches[0].clientY > this.touchStartY
        ) {
          this.scrollUpIntent = true;
        }
      };
      window.addEventListener("touchstart", this.touchStartHandler, {
        passive: true,
      });
      window.addEventListener("touchmove", this.touchMoveHandler, {
        passive: true,
      });

      // Scroll handler is the single source of truth for server notification.
      // Only shows the button once the user has scrolled far enough from bottom,
      // preventing flicker when the user barely scrolls up.
      let ticking = false;
      this.scrollHandler = () => {
        if (!ticking) {
          requestAnimationFrame(() => {
            const scrollTop = window.scrollY;
            const windowHeight = window.innerHeight;
            const docHeight = document.documentElement.scrollHeight;
            const distanceFromBottom = docHeight - scrollTop - windowHeight;
            if (
              this.scrollUpIntent &&
              distanceFromBottom > scrollUpThreshold &&
              !this.serverScrolledUp
            ) {
              this.serverScrolledUp = true;
              this.pushEvent("user_scrolled_up", {});
            } else if (
              distanceFromBottom <= reengageThreshold &&
              this.serverScrolledUp
            ) {
              this.scrollUpIntent = false;
              this.serverScrolledUp = false;
              this.pushEvent("user_at_bottom", {});
            }
            ticking = false;
          });
          ticking = true;
        }
      };
      window.addEventListener("scroll", this.scrollHandler, { passive: true });

      const urlParams = new URLSearchParams(window.location.search);
      if (!urlParams.has("highlight")) {
        this.scrollToBottom();
      } else {
        this.scrollToHighlight(urlParams.get("highlight"));
      }

      // Listen for scroll_to_bottom event from server
      this.handleEvent("scroll_to_bottom", ({ force } = {}) => {
        if (force) {
          this.scrollUpIntent = false;
          this.serverScrolledUp = false;
        }
        // When autoscroll is disabled, only scroll on force (new message send, conversation load)
        if (!this.autoscrollEnabled && !force) {
          return;
        }
        if (!this.serverScrolledUp) {
          this.scrollToBottom();
        }
      });

      // Listen for force_scroll_to_bottom (from the scroll-down button click)
      this.handleEvent("force_scroll_to_bottom", () => {
        this.scrollUpIntent = false;
        this.serverScrolledUp = false;
        this.scrollToBottom();
      });
    },
    updated() {
      this.autoscrollEnabled = this.el.dataset.autoscrollEnabled !== "false";
    },
    destroyed() {
      window.removeEventListener("wheel", this.wheelHandler);
      window.removeEventListener("touchstart", this.touchStartHandler);
      window.removeEventListener("touchmove", this.touchMoveHandler);
      window.removeEventListener("scroll", this.scrollHandler);
    },
    scrollToBottom() {
      requestAnimationFrame(() => {
        if (this.userScrolledUp) return;
        window.scrollTo({
          top: document.documentElement.scrollHeight,
          behavior: "instant",
        });
      });
    },
    scrollToHighlight(messageId) {
      requestAnimationFrame(() => {
        if (messageId) {
          console.log(`Scrolling to message ${messageId}`);
          const element = document.getElementById(`messages-${messageId}`);
          console.log(element);
          if (element) {
            element.scrollIntoView({ behavior: "instant", block: "center" });
          }
        }
      });
    },
  },
};

// Syncs the height of the fixed chat input area to the padding-bottom
// of the message scroll container via a CSS custom property on :root.
// Using :root avoids morphdom stripping inline styles during LiveView patches.
// Hook for auto-scrolling a chat container element (workbench layout where the
// scroll container is the bound element itself, not the window).
const WorkbenchScrollHook = {
  WorkbenchScroll: {
    mounted() {
      this.userScrolledUp = false;
      const reengageThreshold = 24;
      const scrollUpThreshold = 100;
      const buttonId = this.el.dataset.scrollButtonId;
      this.button = buttonId ? document.getElementById(buttonId) : null;

      const updateButton = () => {
        if (!this.button) return;
        if (this.userScrolledUp) {
          this.button.classList.remove("hidden");
        } else {
          this.button.classList.add("hidden");
        }
      };

      let ticking = false;
      this.scrollHandler = () => {
        if (ticking) return;
        ticking = true;
        requestAnimationFrame(() => {
          const { scrollTop, scrollHeight, clientHeight } = this.el;
          const distanceFromBottom = scrollHeight - scrollTop - clientHeight;
          if (distanceFromBottom > scrollUpThreshold) {
            if (!this.userScrolledUp) {
              this.userScrolledUp = true;
              updateButton();
            }
          } else if (distanceFromBottom <= reengageThreshold) {
            if (this.userScrolledUp) {
              this.userScrolledUp = false;
              updateButton();
            }
          }
          ticking = false;
        });
      };
      this.el.addEventListener("scroll", this.scrollHandler, { passive: true });

      this.scrollToBottom = (force = false) => {
        if (this.userScrolledUp && !force) return;
        requestAnimationFrame(() => {
          this.el.scrollTop = this.el.scrollHeight;
        });
      };

      this.handleEvent("scroll_to_bottom", ({ force } = {}) => {
        if (force) {
          this.userScrolledUp = false;
          updateButton();
        }
        this.scrollToBottom(force);
      });

      this.handleEvent("force_scroll_to_bottom", () => {
        this.userScrolledUp = false;
        updateButton();
        this.scrollToBottom(true);
      });

      // Scroll the deep-linked highlighted message into view, if present.
      this.handleEvent("highlight_message", () => {
        requestAnimationFrame(() => {
          // Scroll to the server-rendered ".highlighted" message (one per render,
          // driven by @message_highlight == item.id). We match by class, not by the
          // payload id, because the row's DOM id is the stream-prefixed id, not the
          // raw message id.
          const el = this.el.querySelector(".highlighted");
          if (el) el.scrollIntoView({ block: "center", behavior: "smooth" });
        });
      });

      if (this.button) {
        this.buttonHandler = () => {
          this.userScrolledUp = false;
          updateButton();
          this.scrollToBottom(true);
        };
        this.button.addEventListener("click", this.buttonHandler);
      }

      // Initial scroll on mount
      this.scrollToBottom(true);
    },
    updated() {
      if (!this.userScrolledUp) {
        this.scrollToBottom();
      }
    },
    destroyed() {
      this.el.removeEventListener("scroll", this.scrollHandler);
      if (this.button && this.buttonHandler) {
        this.button.removeEventListener("click", this.buttonHandler);
      }
    },
  },
};

const InputHeightSyncHook = {
  InputHeightSync: {
    mounted() {
      this.syncPadding = () => {
        document.documentElement.style.setProperty(
          "--chat-input-height",
          this.el.offsetHeight + "px",
        );
      };
      this.observer = new ResizeObserver(() => this.syncPadding());
      this.observer.observe(this.el);
      this.syncPadding();
    },
    destroyed() {
      if (this.observer) this.observer.disconnect();
      document.documentElement.style.removeProperty("--chat-input-height");
    },
  },
};

// Mobile sidebar resize handler
// Closes mobile sidebars when resizing to desktop (md breakpoint = 768px)
const MobileSidebarHooks = {
  MobileSidebarHandler: {
    mounted() {
      this.mediaQuery = window.matchMedia("(min-width: 768px)");
      this.handleResize = (e) => {
        if (e.matches) {
          // Screen is now desktop-sized, close mobile sidebars
          this.pushEvent("close_mobile_sidebars", {});
        }
      };
      this.mediaQuery.addEventListener("change", this.handleResize);
    },
    destroyed() {
      if (this.mediaQuery) {
        this.mediaQuery.removeEventListener("change", this.handleResize);
      }
    },
  },
};

// Popover positioning hook for dropdown menus
// Positions the popover relative to its trigger element
const PopoverHooks = {
  PopoverPosition: {
    mounted() {
      const popover = this.el;
      const triggerId = popover.dataset.triggerId;
      const position = popover.dataset.position || "bottom-end";
      const trigger = document.getElementById(triggerId);

      // Handle click outside to close popover (fallback for light dismiss)
      this.handleClickOutside = (e) => {
        if (
          popover.matches(":popover-open") &&
          !popover.contains(e.target) &&
          !trigger?.contains(e.target)
        ) {
          popover.hidePopover();
        }
      };

      // Position the popover when it's toggled
      popover.addEventListener("toggle", (e) => {
        if (e.newState === "open") {
          // Close all other popovers with this hook before opening this one
          document
            .querySelectorAll("[popover][phx-hook='PopoverPosition']")
            .forEach((other) => {
              if (other !== popover && other.matches(":popover-open")) {
                other.hidePopover();
              }
            });
          this.positionPopover(popover, triggerId, position);
          // Add click outside listener when opened
          document.addEventListener("click", this.handleClickOutside, true);
        } else {
          // Remove click outside listener when closed
          document.removeEventListener("click", this.handleClickOutside, true);
        }
      });
    },

    destroyed() {
      if (this.handleClickOutside) {
        document.removeEventListener("click", this.handleClickOutside, true);
      }
    },

    positionPopover(popover, triggerId, position) {
      const trigger = document.getElementById(triggerId);
      if (!trigger) return;

      const triggerRect = trigger.getBoundingClientRect();
      const popoverRect = popover.getBoundingClientRect();

      let top, left;

      // Calculate position based on position attribute
      switch (position) {
        case "bottom-start":
          top = triggerRect.bottom + 4;
          left = triggerRect.left;
          break;
        case "bottom-end":
          top = triggerRect.bottom + 4;
          left = triggerRect.right - popoverRect.width;
          break;
        case "top-start":
          top = triggerRect.top - popoverRect.height - 4;
          left = triggerRect.left;
          break;
        case "top-end":
          top = triggerRect.top - popoverRect.height - 4;
          left = triggerRect.right - popoverRect.width;
          break;
        default:
          top = triggerRect.bottom + 4;
          left = triggerRect.right - popoverRect.width;
      }

      // Ensure popover stays within viewport
      const padding = 8;
      const viewportWidth = window.innerWidth;
      const viewportHeight = window.innerHeight;

      // Adjust horizontal position if needed
      if (left < padding) {
        left = padding;
      } else if (left + popoverRect.width > viewportWidth - padding) {
        left = viewportWidth - popoverRect.width - padding;
      }

      // Adjust vertical position if needed
      if (top < padding) {
        top = triggerRect.bottom + 4; // Flip to bottom
      } else if (top + popoverRect.height > viewportHeight - padding) {
        top = triggerRect.top - popoverRect.height - 4; // Flip to top
      }

      popover.style.position = "fixed";
      popover.style.top = `${top}px`;
      popover.style.left = `${left}px`;
    },
  },
};

// Chart.js hooks for usage analytics
const ChartHooks = {
  StackedBarChart: {
    mounted() {
      const data = JSON.parse(this.el.dataset.chartData);
      const options = this.el.dataset.chartOptions
        ? JSON.parse(this.el.dataset.chartOptions)
        : {};
      this.chart = new Chart(this.el.getContext("2d"), {
        type: "bar",
        data: data,
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: {
            legend: { position: "bottom" },
          },
          scales: {
            x: { stacked: true },
            y: { stacked: true, beginAtZero: true },
          },
          ...options,
        },
      });
    },
    updated() {
      const data = JSON.parse(this.el.dataset.chartData);
      this.chart.data = data;
      this.chart.update();
    },
    destroyed() {
      this.chart?.destroy();
    },
  },

  DoughnutChart: {
    mounted() {
      const data = JSON.parse(this.el.dataset.chartData);
      this.chart = new Chart(this.el.getContext("2d"), {
        type: "doughnut",
        data: data,
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: {
            legend: { position: "bottom" },
          },
        },
      });
    },
    updated() {
      const data = JSON.parse(this.el.dataset.chartData);
      this.chart.data = data;
      this.chart.update();
    },
    destroyed() {
      this.chart?.destroy();
    },
  },

  Histogram: {
    mounted() {
      const data = JSON.parse(this.el.dataset.chartData);
      const median = this.el.dataset.median
        ? parseFloat(this.el.dataset.median)
        : null;
      this.chart = new Chart(this.el.getContext("2d"), {
        type: "bar",
        data: data,
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: {
            legend: { display: false },
            annotation: median
              ? {
                  annotations: {
                    medianLine: {
                      type: "line",
                      xMin: median,
                      xMax: median,
                      borderColor: "rgb(255, 99, 132)",
                      borderWidth: 2,
                      label: {
                        display: true,
                        content: `Median: ${median}`,
                      },
                    },
                  },
                }
              : {},
          },
          scales: {
            x: { title: { display: true, text: "Tokens" } },
            y: { title: { display: true, text: "Count" }, beginAtZero: true },
          },
        },
      });
    },
    updated() {
      const data = JSON.parse(this.el.dataset.chartData);
      this.chart.data = data;
      this.chart.update();
    },
    destroyed() {
      this.chart?.destroy();
    },
  },

  ScatterChart: {
    mounted() {
      const data = JSON.parse(this.el.dataset.chartData);
      this.chart = new Chart(this.el.getContext("2d"), {
        type: "scatter",
        data: data,
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: {
            legend: {
              display: true,
              position: "bottom",
              labels: {
                boxWidth: 12,
                padding: 8,
                font: { size: 10 },
              },
            },
            tooltip: {
              callbacks: {
                label: (context) => {
                  const point = context.raw;
                  return `${context.dataset.label}: $${point.x.toFixed(4)}, ${point.y} msgs`;
                },
              },
            },
          },
          scales: {
            x: {
              title: { display: true, text: "Cost ($)" },
              beginAtZero: true,
            },
            y: {
              title: { display: true, text: "Messages" },
              beginAtZero: true,
            },
          },
        },
      });
    },
    updated() {
      const data = JSON.parse(this.el.dataset.chartData);
      this.chart.data = data;
      this.chart.update();
    },
    destroyed() {
      this.chart?.destroy();
    },
  },

  LineChart: {
    mounted() {
      const data = JSON.parse(this.el.dataset.chartData);
      this.chart = new Chart(this.el.getContext("2d"), {
        type: "line",
        data: data,
        options: {
          responsive: true,
          maintainAspectRatio: false,
          plugins: { legend: { display: true, position: "top" } },
          scales: {
            x: { ticks: { maxTicksLimit: 12 } },
            y: { beginAtZero: true, ticks: { stepSize: 1 } },
          },
        },
      });
    },
    updated() {
      const data = JSON.parse(this.el.dataset.chartData);
      this.chart.data = data;
      this.chart.update();
    },
    destroyed() {
      this.chart?.destroy();
    },
  },
};

// Hook for code blocks in tool output (copy button + syntax highlighting)
const ToolCodeBlockHooks = {
  ToolCodeBlock: {
    mounted() {
      this.setup();
    },
    updated() {
      this.setup();
    },
    setup() {
      // Syntax highlight with highlight.js
      if (window.hljs) {
        const code = this.el.querySelector(
          "code[class*='language-']:not(.hljs)",
        );
        if (code) hljs.highlightElement(code);
      }

      // Bind copy button
      const btn = this.el.querySelector("[data-copy-btn]");
      if (btn && !btn._bound) {
        btn._bound = true;
        btn.addEventListener("click", () => {
          const pre = this.el.querySelector("pre");
          if (!pre) return;
          navigator.clipboard.writeText(pre.textContent).then(() => {
            const copyIcon = btn.querySelector("[data-icon='copy']");
            const checkIcon = btn.querySelector("[data-icon='check']");
            if (copyIcon) copyIcon.classList.add("hidden");
            if (checkIcon) checkIcon.classList.remove("hidden");
            setTimeout(() => {
              if (copyIcon) copyIcon.classList.remove("hidden");
              if (checkIcon) checkIcon.classList.add("hidden");
            }, 2000);
          });
        });
      }
    },
  },
};

// Hook to render KaTeX and Mermaid inside message content.
// During streaming, the server sends throttled stream_inserts with rendered markdown.
// KaTeX/Mermaid post-processing only runs once the message is complete.
const RichContentHooks = {
  RichContent: {
    mounted() {
      if (this.el.dataset.complete !== "false") {
        this.renderContent();
      }
    },
    updated() {
      if (this.el.dataset.complete === "true") {
        this.renderContent();
      }
    },
    destroyed() {
      if (this._mermaidListener) {
        window.removeEventListener("mermaid:loaded", this._mermaidListener);
      }
    },
    renderContent() {
      // Render KaTeX blocks (from ```math code fences)
      if (window.katex) {
        this.el.querySelectorAll(".katex-block").forEach((el) => {
          const latex = el.getAttribute("data-latex");
          if (latex && !el.querySelector(".katex")) {
            try {
              katex.render(latex, el, {
                displayMode: true,
                throwOnError: false,
                trust: true,
              });
            } catch (e) {
              console.error("KaTeX render error:", e);
            }
          }
        });

        // Render inline/display math (from $...$ and $$...$$ syntax)
        this.el
          .querySelectorAll("span[data-math-style]:not(.katex-rendered)")
          .forEach((el) => {
            const latex = el.textContent;
            const displayMode =
              el.getAttribute("data-math-style") === "display";
            if (latex) {
              try {
                katex.render(latex, el, {
                  displayMode,
                  throwOnError: false,
                  trust: true,
                });
                el.classList.add("katex-rendered");
              } catch (e) {
                console.error("KaTeX render error:", e);
              }
            }
          });
      }

      // Render Mermaid diagrams
      this.renderMermaid();

      // Syntax highlight code blocks with highlight.js
      if (window.hljs) {
        this.el
          .querySelectorAll("pre > code[class*='language-']:not(.hljs)")
          .forEach((el) => {
            hljs.highlightElement(el);
          });
      }

      // Add copy buttons to code blocks (skip mermaid diagrams)
      this.el
        .querySelectorAll("pre:not([data-copy-injected]):not(.mermaid)")
        .forEach((pre) => {
          pre.setAttribute("data-copy-injected", "true");
          pre.style.position = "relative";
          pre.classList.add("group/code");

          const btn = document.createElement("button");
          btn.type = "button";
          btn.title = "Copy";
          btn.className =
            "absolute top-1.5 right-1.5 btn btn-ghost btn-xs h-6 min-h-6 px-1.5 opacity-0 group-hover/code:opacity-100 transition-opacity z-10 bg-base-300/80 hover:bg-base-300";
          btn.innerHTML =
            '<span data-icon="copy"><svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/></svg></span>' +
            '<span data-icon="check" class="hidden"><svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="text-success"><polyline points="20 6 9 17 4 12"/></svg></span>';

          btn.addEventListener("click", (e) => {
            e.stopPropagation();
            const text = pre.textContent;
            navigator.clipboard.writeText(text).then(() => {
              const copyIcon = btn.querySelector('[data-icon="copy"]');
              const checkIcon = btn.querySelector('[data-icon="check"]');
              if (copyIcon) copyIcon.classList.add("hidden");
              if (checkIcon) checkIcon.classList.remove("hidden");
              setTimeout(() => {
                if (copyIcon) copyIcon.classList.remove("hidden");
                if (checkIcon) checkIcon.classList.add("hidden");
              }, 2000);
            });
          });

          pre.appendChild(btn);
        });
    },
    renderMermaid() {
      // Skip mermaid rendering while the message is still streaming —
      // diagrams change on every chunk which is visually disruptive.
      // They will render once the final complete message arrives.
      if (this.el.dataset.complete === "false") return;

      if (!window.mermaid) {
        // Mermaid not loaded yet (async ES module) — listen for it
        if (!this._mermaidListener && this.el.querySelector("pre.mermaid")) {
          this._mermaidListener = () => {
            this.renderMermaid();
            window.removeEventListener("mermaid:loaded", this._mermaidListener);
            this._mermaidListener = null;
          };
          window.addEventListener("mermaid:loaded", this._mermaidListener);
        }
        return;
      }

      // Find mermaid elements that need rendering (no SVG yet)
      const mermaidEls = Array.from(
        this.el.querySelectorAll("pre.mermaid"),
      ).filter((el) => !el.querySelector("svg"));

      if (mermaidEls.length > 0) {
        // Decode HTML entities in mermaid content (sanitizer encodes --> as --&gt;)
        mermaidEls.forEach((el) => {
          const textarea = document.createElement("textarea");
          textarea.innerHTML = el.innerHTML;
          el.innerHTML = textarea.value;
        });
        mermaid.run({ nodes: mermaidEls }).catch(() => {
          // Incomplete or invalid diagram — will retry on next update
        });
      }
    },
  },
};

// Hook for detecting text selection in message bubbles and showing "Ask Chat" button
const MessageTextSelectionHook = {
  MessageTextSelection: {
    mounted() {
      this._popup = null;
      this._removalTimer = null;
      this._mouseDown = false;
      this._selectionPending = false;
      this._onScroll = () => this._removePopup();
      this._onMouseDown = () => {
        this._mouseDown = true;
        this._removePopup();
      };
      this._onMouseUp = () => {
        this._mouseDown = false;
        if (this._selectionPending) {
          this._selectionPending = false;
          this._handleSelectionChange();
        }
      };
      this._onSelectionChange = () => {
        if (this._mouseDown) {
          // Dragging — wait for mouseup
          this._selectionPending = true;
          return;
        }
        this._handleSelectionChange();
      };
      document.addEventListener("selectionchange", this._onSelectionChange);
      document.addEventListener("mousedown", this._onMouseDown);
      document.addEventListener("mouseup", this._onMouseUp);
      this.el.addEventListener("scroll", this._onScroll, { passive: true });
    },

    updated() {
      this._removePopup();
    },

    destroyed() {
      document.removeEventListener("selectionchange", this._onSelectionChange);
      document.removeEventListener("mousedown", this._onMouseDown);
      document.removeEventListener("mouseup", this._onMouseUp);
      this.el.removeEventListener("scroll", this._onScroll);
      clearTimeout(this._removalTimer);
      this._removePopup();
    },

    _handleSelectionChange() {
      const sel = window.getSelection();
      if (!sel || sel.isCollapsed || !sel.rangeCount) {
        // Delay removal so click on popup isn't lost
        this._removalTimer = setTimeout(() => this._removePopup(), 200);
        return;
      }

      const text = sel.toString().trim();
      if (!text) {
        this._removePopup();
        return;
      }

      // Check if selection is inside a message-text div within this container
      const range = sel.getRangeAt(0);
      const msgTextEl =
        range.commonAncestorContainer.nodeType === 1
          ? range.commonAncestorContainer.closest?.("[id^='message-text-']")
          : range.commonAncestorContainer.parentElement?.closest?.(
              "[id^='message-text-']",
            );

      if (!msgTextEl || !this.el.contains(msgTextEl)) {
        this._removePopup();
        return;
      }

      // Extract message ID from the element ID (message-text-{uuid})
      const messageId = msgTextEl.id.replace("message-text-", "");

      // Determine message role from data attribute on the message wrapper
      const bubbleWrapper = msgTextEl.closest("[data-role]");
      const role = bubbleWrapper?.dataset.role || "agent";

      this._showPopup(range, text, messageId, role);
    },

    _showPopup(range, text, messageId, role) {
      this._removePopup();

      const rect = range.getBoundingClientRect();
      const containerRect = this.el.getBoundingClientRect();

      const popup = document.createElement("button");
      popup.className =
        "message-selection-popup btn btn-primary btn-xs gap-1 shadow-lg z-50";
      popup.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m3 21 1.9-5.7a8.5 8.5 0 1 1 3.8 3.8z"/></svg> Ask Chat`;
      popup.style.position = "absolute";
      popup.style.left = `${rect.left - containerRect.left + rect.width / 2}px`;

      // Flip below selection if too close to the top of the scroll viewport
      const scrollContainer =
        this.el.closest("#chat-scroll-container") || this.el;
      const scrollRect = scrollContainer.getBoundingClientRect();
      const spaceAbove = rect.top - scrollRect.top;

      if (spaceAbove < 40) {
        // Show below selection
        popup.style.top = `${rect.bottom - containerRect.top + 8}px`;
        popup.style.transform = "translate(-50%, 0)";
      } else {
        // Show above selection (default)
        popup.style.top = `${rect.top - containerRect.top - 8}px`;
        popup.style.transform = "translate(-50%, -100%)";
      }

      popup.addEventListener("mousedown", (e) => {
        e.preventDefault();
        e.stopPropagation();
        clearTimeout(this._removalTimer);

        this.pushEvent("ask_about_message_selection", {
          text: text.substring(0, 6000),
          message_id: messageId,
          role: role,
        });

        window.getSelection()?.removeAllRanges();
        this._removePopup();
      });

      this.el.appendChild(popup);
      this._popup = popup;
    },

    _removePopup() {
      if (this._popup) {
        this._popup.remove();
        this._popup = null;
      }
    },
  },
};

// TipTap rich text editor hook (replaces DraftSelection)

const SUBTLE_DELAY_MS = 5000;
const ESCALATED_DELAY_MS = 20000;

const ConnectionStatusHook = {
  mounted() {
    this._subtle = this.el.querySelector("[data-stage=subtle]");
    this._escalated = this.el.querySelector("[data-stage=escalated]");
  },
  disconnected() {
    this._clearTimers();
    this._subtle.classList.add("hidden");
    this._escalated.classList.add("hidden");
    this._timer1 = setTimeout(() => {
      this._subtle.classList.remove("hidden");
      this.el.classList.remove("hidden");
    }, SUBTLE_DELAY_MS);
    this._timer2 = setTimeout(() => {
      this._subtle.classList.add("hidden");
      this._escalated.classList.remove("hidden");
    }, ESCALATED_DELAY_MS);
  },
  reconnected() {
    this._clearTimers();
    this.el.classList.add("hidden");
    this._subtle.classList.remove("hidden");
    this._escalated.classList.add("hidden");
  },
  destroyed() {
    this._clearTimers();
  },
  _clearTimers() {
    clearTimeout(this._timer1);
    clearTimeout(this._timer2);
  },
};

const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  .getAttribute("content");
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: {
    ...colocatedHooks,
    ...BrainHooks,
    ...GlobalSearchHook,
    ...AutoScrollHook,
    ...AutoScrollContentHook,
    ...WorkbenchScrollHook,
    ...InputHeightSyncHook,
    ...MobileSidebarHooks,

    ...ChartHooks,
    ...PopoverHooks,
    ...RichContentHooks,
    ...MessageTextSelectionHook,
    ...ToolCodeBlockHooks,
    TiptapEditor,
    PdfViewer,
    ServiceCapture,
    BrainTiptapEditor,
    DraggableMessage,
    ResizablePanel,
    FilesDropTarget,
    FilesDragSource,
    ConnectionStatus: ConnectionStatusHook,
  },
});

// Show progress bar on live navigation and form submits
topbar.config({ barColors: { 0: "#29d" }, shadowColor: "rgba(0, 0, 0, .3)" });
window.addEventListener("phx:page-loading-start", (_info) => topbar.show(300));
window.addEventListener("phx:page-loading-stop", (_info) => topbar.hide());

// Copy to clipboard handler
window.addEventListener("phx:copy", (event) => {
  const target = event.target;
  const text =
    target.tagName === "INPUT" || target.tagName === "TEXTAREA"
      ? target.value
      : target.innerText || target.textContent;
  navigator.clipboard
    .writeText(text)
    .then(() => {
      // Optional: Show a brief "Copied!" tooltip or change button state
      console.log("Copied to clipboard");
    })
    .catch((err) => {
      console.error("Failed to copy:", err);
    });
});

// Copy to clipboard handler for server-pushed text
window.addEventListener("phx:copy_to_clipboard", (event) => {
  const text = event.detail.text;
  if (text) {
    navigator.clipboard.writeText(text).catch((err) => {
      console.error("Failed to copy:", err);
    });
  }
});

// connect if there are any LiveViews on the page
liveSocket.connect();

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();

      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (_e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );

      window.liveReloader = reloader;
    },
  );
}

// Register the service worker so the classic app is installable as a PWA and
// repeat visits serve cached, content-hashed assets. The worker is a no-op in
// development (see priv/static/sw.js), so registering everywhere is safe.
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/sw.js").catch((err) => {
      console.error("Service worker registration failed:", err);
    });
  });
}
