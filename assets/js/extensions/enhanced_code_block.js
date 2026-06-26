import CodeBlockLowlight from "@tiptap/extension-code-block-lowlight";
import { common, createLowlight } from "lowlight";

const lowlight = createLowlight(common);

/**
 * EnhancedCodeBlock extends CodeBlockLowlight to add a toggleable
 * preview for mermaid diagrams and math/LaTeX code blocks.
 *
 * - Mermaid/math: NodeView with edit/preview toggle
 * - Other languages: basic pre>code (lowlight plugin handles highlighting)
 */
export const EnhancedCodeBlock = CodeBlockLowlight.extend({
  addNodeView() {
    return ({ node, editor, getPos }) => {
      const language = node.attrs.language;
      const isPreviewable = language === "mermaid" || language === "math";

      if (!isPreviewable) {
        // Basic NodeView that lets the lowlight ProseMirror plugin handle highlighting
        const pre = document.createElement("pre");
        const code = document.createElement("code");
        if (language) code.classList.add(`language-${language}`);
        pre.appendChild(code);

        return {
          dom: pre,
          contentDOM: code,
          update(updatedNode) {
            if (updatedNode.type.name !== "codeBlock") return false;
            const newLang = updatedNode.attrs.language;
            // If language changed to a previewable one, recreate the NodeView
            if (newLang === "mermaid" || newLang === "math") return false;
            code.className = newLang ? `language-${newLang}` : "";
            return true;
          },
        };
      }

      // --- Previewable code block with edit/preview toggle ---
      let mode = "edit";
      let debounceTimer;

      const wrapper = document.createElement("div");
      wrapper.classList.add("enhanced-code-block");
      wrapper.setAttribute("data-language", language);
      wrapper.setAttribute("data-mode", mode);

      // Toggle button — contenteditable=false so ProseMirror doesn't intercept events
      const toolbar = document.createElement("div");
      toolbar.classList.add("code-block-toolbar");
      toolbar.contentEditable = "false";

      const toggleBtn = document.createElement("button");
      toggleBtn.type = "button";
      toggleBtn.classList.add("code-block-toggle");
      toggleBtn.textContent = "Preview";
      // Use mousedown — ProseMirror swallows click events inside NodeViews
      toggleBtn.addEventListener("mousedown", (e) => {
        e.preventDefault();
        e.stopPropagation();
        if (mode === "edit") {
          mode = "preview";
          renderPreview(getSourceText());
        } else {
          mode = "edit";
          // Re-focus the editor in the code block
          if (typeof getPos === "function") {
            editor.commands.focus(getPos() + 1);
          }
        }
        wrapper.setAttribute("data-mode", mode);
        toggleBtn.textContent = mode === "edit" ? "Preview" : "Edit";
      });
      toolbar.appendChild(toggleBtn);
      wrapper.appendChild(toolbar);

      // Editable source
      const pre = document.createElement("pre");
      const code = document.createElement("code");
      code.classList.add(`language-${language}`);
      pre.appendChild(code);
      wrapper.appendChild(pre);

      // Preview container — contenteditable=false so ProseMirror ignores it
      const preview = document.createElement("div");
      preview.classList.add("code-preview");
      preview.contentEditable = "false";
      wrapper.appendChild(preview);

      function getSourceText() {
        return code.textContent || "";
      }

      function renderPreview(text) {
        if (!text.trim()) {
          preview.innerHTML =
            '<span class="text-xs text-base-content/50">Empty</span>';
          return;
        }
        if (language === "mermaid") {
          renderMermaidPreview(text, preview);
        } else if (language === "math") {
          renderMathPreview(text, preview);
        }
      }

      return {
        dom: wrapper,
        contentDOM: code,

        // Prevent ProseMirror from handling events on toolbar/preview
        stopEvent(event) {
          if (toolbar.contains(event.target) || preview.contains(event.target))
            return true;
          return false;
        },

        // Prevent ProseMirror from re-rendering when we change toolbar/preview DOM
        ignoreMutation(mutation) {
          if (!code.contains(mutation.target)) return true;
          return false;
        },

        update(updatedNode) {
          if (updatedNode.type.name !== "codeBlock") return false;
          const newLang = updatedNode.attrs.language;
          if (newLang !== "mermaid" && newLang !== "math") return false;

          wrapper.setAttribute("data-language", newLang);
          code.className = `language-${newLang}`;

          // Re-render preview if in preview mode
          if (mode === "preview") {
            clearTimeout(debounceTimer);
            debounceTimer = setTimeout(
              () => renderPreview(updatedNode.textContent || ""),
              300,
            );
          }
          return true;
        },
        destroy() {
          clearTimeout(debounceTimer);
        },
      };
    };
  },
}).configure({
  lowlight,
});

function renderMermaidPreview(text, container) {
  if (!window.mermaid) {
    window.addEventListener(
      "mermaid:loaded",
      () => renderMermaidPreview(text, container),
      { once: true },
    );
    container.innerHTML =
      '<span class="text-xs text-base-content/50">Loading mermaid...</span>';
    return;
  }

  const id = `mermaid-preview-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  mermaid
    .render(id, text)
    .then(({ svg }) => {
      container.innerHTML = svg;
    })
    .catch(() => {
      container.innerHTML =
        '<span class="text-xs text-error/70">Invalid mermaid syntax</span>';
    });
}

function renderMathPreview(text, container) {
  if (!window.katex) {
    container.innerHTML =
      '<span class="text-xs text-base-content/50">Loading KaTeX...</span>';
    return;
  }

  try {
    katex.render(text, container, {
      displayMode: true,
      throwOnError: false,
    });
  } catch {
    container.innerHTML =
      '<span class="text-xs text-error/70">Invalid LaTeX syntax</span>';
  }
}
