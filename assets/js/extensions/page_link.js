/**
 * PageLink TipTap extension.
 *
 * Triggers a suggestion popup when the user types `[[` in the editor.
 * Shows a filtered list of brain pages and inserts `[[Page Name]]` on
 * selection.
 *
 * The editor saves the page body as ProseMirror JSON, which the server
 * converts to markdown; `[[Page Title]]` survives the round trip via the
 * `pageRef` inline atom defined in `extensions/brain_blocks.js` and the
 * server-side serializer in `Magus.Brain.ProseMirrorProfile`. The Elixir side
 * (`Magus.Brain.BodyParser`) scans the saved markdown to maintain
 * `brain_page_links` rows.
 */
import { Extension } from "@tiptap/core";
import Suggestion from "@tiptap/suggestion";
import { Plugin, PluginKey } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import tippy from "tippy.js";

const pageLinkPluginKey = new PluginKey("pageLink");
const pageLinkDecoKey = new PluginKey("pageLinkDecorations");

/**
 * Creates a PageLink extension configured with a list of pages.
 *
 * @param {Array<{id: string, title: string}>} pages - Brain pages for the popup
 * @returns {Extension}
 */
export function createPageLink(pages = [], { onPageRefClick } = {}) {
  return Extension.create({
    name: "pageLink",

    addOptions() {
      return { pages, onPageRefClick };
    },

    addCommands() {
      return {
        rebuildPageRefs: () => ({ state, dispatch }) => {
          if (dispatch) {
            dispatch(state.tr.setMeta(pageLinkDecoKey, "rebuild"));
          }

          return true;
        },
      };
    },

    addProseMirrorPlugins() {
      const extensionPages = this.options.pages;

      return [
        Suggestion({
          editor: this.editor,
          pluginKey: pageLinkPluginKey,
          char: "[[",
          allowSpaces: true,

          items: ({ query }) => {
            const q = query.toLowerCase();
            return extensionPages
              .filter((page) => page.title.toLowerCase().includes(q))
              .slice(0, 10);
          },

          command: ({ editor, range, props }) => {
            editor
              .chain()
              .focus()
              .deleteRange(range)
              .insertContent(`[[${props.title}]]`)
              .run();
          },

          render: () => {
            let component = null;
            let popup = null;

            return {
              onStart: (props) => {
                component = new PageLinkList(props);

                popup = tippy("body", {
                  getReferenceClientRect: props.clientRect,
                  appendTo: () => document.body,
                  content: component.element,
                  showOnCreate: true,
                  interactive: true,
                  trigger: "manual",
                  placement: "bottom-start",
                  offset: [0, 4],
                });
              },

              onUpdate: (props) => {
                if (component) component.update(props);
                popup?.[0]?.setProps({
                  getReferenceClientRect: props.clientRect,
                });
              },

              onKeyDown: (props) => {
                if (props.event.key === "Escape") {
                  popup?.[0]?.hide();
                  return true;
                }
                return component?.onKeyDown(props.event) ?? false;
              },

              onExit: () => {
                popup?.[0]?.destroy();
                component?.destroy();
              },
            };
          },
        }),
        createPageRefDecoPlugin(extensionPages, this.options.onPageRefClick),
      ];
    },
  });
}

const PAGE_REF_RE = /\[\[([^\]]+)\]\]/g;

function createPageRefDecoPlugin(pages, onPageRefClick) {
  let currentPages = pages;

  return new Plugin({
    key: pageLinkDecoKey,
    state: {
      init(_, state) {
        return buildDecorations(state.doc, currentPages);
      },
      apply(tr, old) {
        if (tr.getMeta(pageLinkDecoKey) === "rebuild" || tr.docChanged) {
          return buildDecorations(tr.doc, currentPages);
        }
        return old;
      },
    },
    props: {
      decorations(state) {
        return this.getState(state);
      },
      handleDOMEvents: {
        mousedown(view, event) {
          if (!onPageRefClick) return false;
          const ref = event.target.closest(".brain-page-ref");
          if (!ref) return false;

          const match = ref.textContent.match(/^\[\[(.+)\]\]$/);
          if (match) {
            event.preventDefault();
            event.stopPropagation();
            onPageRefClick(match[1]);
            return true;
          }
          return false;
        },
      },
    },
    view() {
      return {
        update(view) {
          if (currentPages !== pages) {
            currentPages = pages;
            const { tr } = view.state;
            tr.setMeta(pageLinkDecoKey, "rebuild");
            view.dispatch(tr);
          }
        },
      };
    },
  });
}

function buildDecorations(doc, pages) {
  const decos = [];
  const titleSet = new Set(pages.map((p) => p.title));

  doc.descendants((node, pos) => {
    if (!node.isText) return;

    const text = node.text;
    let match;
    PAGE_REF_RE.lastIndex = 0;

    while ((match = PAGE_REF_RE.exec(text)) !== null) {
      const title = match[1];
      if (!titleSet.has(title)) continue;

      const start = pos + match.index;
      const end = start + match[0].length;
      decos.push(
        Decoration.inline(start, end, {
          class: "brain-page-ref",
          nodeName: "a",
        }, {
          pageTitle: title,
        }),
      );
    }
  });

  return DecorationSet.create(doc, decos);
}

/**
 * Renders the page link suggestion popup.
 * Reuses slash-command-menu CSS classes for visual consistency.
 */
class PageLinkList {
  constructor({ items, command }) {
    this.items = items;
    this.command = command;
    this.selectedIndex = 0;
    this.element = document.createElement("div");
    this.element.className = "slash-command-menu";
    this.render();
  }

  update({ items, command }) {
    this.items = items;
    this.command = command;
    this.selectedIndex = 0;
    this.render();
  }

  onKeyDown(event) {
    if (event.key === "ArrowUp") {
      this.selectedIndex =
        (this.selectedIndex + this.items.length - 1) % this.items.length;
      this.render();
      return true;
    }
    if (event.key === "ArrowDown") {
      this.selectedIndex = (this.selectedIndex + 1) % this.items.length;
      this.render();
      return true;
    }
    if (event.key === "Enter") {
      const item = this.items[this.selectedIndex];
      if (item) {
        this.command(item);
        return true;
      }
      return false;
    }
    return false;
  }

  render() {
    this.element.innerHTML = "";

    if (this.items.length === 0) {
      const empty = document.createElement("div");
      empty.className = "slash-command-item";
      empty.style.opacity = "0.5";
      empty.style.cursor = "default";
      empty.textContent = "No pages found";
      this.element.appendChild(empty);
      return;
    }

    this.items.forEach((item, index) => {
      const button = document.createElement("button");
      button.className = `slash-command-item${index === this.selectedIndex ? " is-selected" : ""}`;
      button.innerHTML = `
        <span class="slash-command-item-icon">&#128196;</span>
        <span>${item.title}</span>
      `;
      button.addEventListener("mousedown", (e) => {
        e.preventDefault();
        this.command(item);
      });
      button.addEventListener("mouseenter", () => {
        this.selectedIndex = index;
        this.render();
      });
      this.element.appendChild(button);
    });
  }

  destroy() {
    this.element.remove();
  }
}
