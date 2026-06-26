defmodule MagusWeb.ChatLive.Components.Brain.BrainPaneComponent do
  @moduledoc """
  LiveComponent for the brain page editor pane.

  Renders a right-side pane with:
  - Header showing brain icon and page title
  - TipTap-based editor area for page content
  - Bottom tabbed panels (Outline, Sources, Related, Activity)

  The component is presentational. Editor saves are pushed from the
  BrainTiptapEditor JS hook directly to the parent LiveView, which delegates
  to BrainHandlers for persistence.
  """

  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  require Logger

  import MagusWeb.Components.PresenceIndicator
  import MagusWeb.Workbench.Components.InlineEditActions

  @max_drop_entries 5
  @max_drop_size 50_000_000

  @impl true
  def mount(socket) do
    {:ok,
     socket
     |> assign(:active_tab, :outline)
     |> assign(:bottom_panel_open, false)
     |> assign(:editing_title, false)
     |> assign(:title_value, "")
     |> assign(:breadcrumb_ancestors, [])
     |> allow_upload(:brain_drop,
       accept: :any,
       max_entries: @max_drop_entries,
       max_file_size: @max_drop_size,
       auto_upload: true,
       progress: &__MODULE__.handle_drop_progress/3
     )}
  end

  @impl true
  def update(assigns, socket) do
    # Default `role` to `"primary"` so callers that don't opt into the
    # role gating still render the standard header (Open chat button).
    role = Map.get(assigns, :role, "primary")
    companion_present? = Map.get(assigns, :companion_present?, false)

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:role, role)
     |> assign(:companion_present?, companion_present?)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      data-brain-pane
      data-role={@role}
      class="flex flex-col h-full border-l border-base-300 bg-base-100 relative"
    >
      <%!-- Header --%>
      <div class="flex items-center justify-between gap-3 md:px-4 px-14 py-2 border-b border-base-300/50 bg-base-100/80 backdrop-blur-sm">
        <div class="flex flex-col min-w-0 flex-1 gap-0.5">
          <div class="flex items-center gap-2 min-w-0">
            <span class="text-base flex-shrink-0">
              <%= if @brain.icon do %>
                {@brain.icon}
              <% else %>
                <.icon name="lucide-brain" class="w-4 h-4 text-primary" />
              <% end %>
            </span>
            <%= if @editing_title do %>
              <form
                phx-submit="save_title"
                phx-target={@myself}
                class="flex-1 min-w-0 flex items-center gap-1"
              >
                <input
                  type="text"
                  name="title"
                  value={@title_value}
                  phx-keydown="title_keydown"
                  phx-target={@myself}
                  class="input input-xs input-bordered flex-1 min-w-0 text-sm font-medium"
                  phx-mounted={JS.focus()}
                  id="brain-title-input"
                />
                <.inline_edit_actions cancel_event="cancel_editing_title" target={@myself} size={:sm} />
              </form>
            <% else %>
              <div class="flex items-center gap-1 min-w-0 text-sm">
                <%= for crumb <- truncate_breadcrumbs(@breadcrumb_ancestors) do %>
                  <span class="flex items-center gap-1 shrink-0">
                    <%= case crumb do %>
                      <% {:page, ancestor} -> %>
                        <button
                          type="button"
                          class="text-base-content/60 hover:text-primary cursor-pointer"
                          phx-click="open_related_page"
                          phx-value-brain-id={@brain.id}
                          phx-value-page-id={ancestor.id}
                          phx-target={@myself}
                        >
                          {ancestor.title || "Untitled"}
                        </button>
                      <% :ellipsis -> %>
                        <span
                          class="text-base-content/40"
                          title={breadcrumb_ellipsis_title(@breadcrumb_ancestors)}
                        >
                          …
                        </span>
                    <% end %>
                    <span class="text-base-content/30">/</span>
                  </span>
                <% end %>
                <span
                  class="font-medium text-base-content truncate cursor-pointer hover:text-primary"
                  phx-click="start_editing_title"
                  phx-target={@myself}
                >
                  {@page.title || "Untitled"}
                </span>
              </div>
            <% end %>
          </div>
          <div class="text-xs text-base-content/60 truncate">
            Updated {MagusWeb.Workbench.Components.RelativeTime.relative(@page.updated_at)}
          </div>
        </div>
        <div class="flex items-center gap-1">
          <%!-- Read-only visibility indicator. Sharing is managed from the
               brain edit modal and the brain nav row. The pill updates
               live when `is_shared_to_workspace` changes on the brain. --%>
          <.visibility_pill brain={@brain} />
          <button
            :if={@role == "primary" and not @companion_present?}
            type="button"
            data-brain-open-chat
            phx-click="open_companion_chat"
            class="wb-pill-btn"
            title="Open chat about this page"
          >
            <.icon name="lucide-message-square" class="w-4 h-4" />
            <span>Open chat</span>
          </button>
          <button
            :if={@role == "companion"}
            type="button"
            phx-click="close_self_companion"
            class="wb-pill-btn wb-pill-btn-square"
            title="Close"
          >
            <.icon name="lucide-x" class="w-4 h-4" />
          </button>
          <.presence_indicator
            viewers={assigns[:brain_page_viewers] || []}
            current_user_id={@current_user.id}
            variant={:dots}
            topic={"presence:page:#{@page.id}"}
          />
        </div>
      </div>

      <%!-- Editor. The server is the source of truth; it supplies the page
           body as ProseMirror JSON (`:prosemirror` calc) and the hook hydrates
           via `setContent(JSON)` (no client-side markdown conversion).
           `data-lock-version` lets the hook detect remote updates and pick
           reload vs. conflict-toast. --%>
      <div class="flex-1 overflow-y-auto min-h-0 bg-wb-surface relative">
        <%!-- Empty pages are editable: a freshly created page has `body: nil`
             and the editor hydrates an empty doc (the parent LiveView falls
             back to the default empty ProseMirror doc). The hook only
             persists on user input, so mounting on an empty page never
             clobbers anything. (The old `blank_body?` placeholder was a Phase
             C migration safety net, obsolete now that cutover is complete and
             every page either has a body or is a legitimately empty new
             page.) --%>
        <div
          id={"brain-editor-#{@page.id}"}
          phx-hook="BrainTiptapEditor"
          phx-drop-target={@uploads.brain_drop.ref}
          phx-update="ignore"
          data-page-id={@page.id}
          data-page-title={@page.title || "Untitled"}
          data-content={@editor_content_json}
          data-lock-version={@page.lock_version}
          data-pages={@brain_pages_json}
          class="prose prose-sm max-w-none px-6 py-4"
        >
          <div data-tiptap-editor></div>
        </div>
        <.live_file_input upload={@uploads.brain_drop} class="hidden" />
        <.version_overlay
          :if={assigns[:viewing_version]}
          viewing_version={@viewing_version}
          myself={@myself}
        />
      </div>

      <%!-- Bottom tabs (resizable, closable) --%>
      <div
        id="brain-bottom-panels"
        phx-hook="ResizablePanel"
        class={[
          "border-t border-base-300/50 flex flex-col shrink-0",
          if(!@bottom_panel_open, do: "!h-auto !min-h-0")
        ]}
        style={if @bottom_panel_open, do: "height: 180px; min-height: 80px; max-height: 50vh;"}
      >
        <div
          :if={@bottom_panel_open}
          class="h-1 cursor-row-resize bg-transparent hover:bg-primary/20 active:bg-primary/30 transition-colors flex-shrink-0 brain-resize-handle"
        />
        <div class="flex border-b border-base-300/50 bg-base-200/30">
          <button
            :for={tab <- [:outline, :sources, :related, :activity]}
            phx-click="switch_brain_tab"
            phx-value-tab={tab}
            phx-target={@myself}
            class={[
              "px-3 py-1.5 text-xs cursor-pointer",
              if(@active_tab == tab,
                do: "text-primary border-b-2 border-primary font-medium",
                else: "text-base-content/50 hover:text-base-content/70"
              )
            ]}
          >
            {tab_label(tab)}
          </button>
          <div class="flex-1" />
          <button
            phx-click="toggle_bottom_panel"
            phx-target={@myself}
            class="px-2 py-1.5 text-base-content/40 hover:text-base-content/70 cursor-pointer"
          >
            <.icon
              name={if @bottom_panel_open, do: "lucide-chevron-down", else: "lucide-chevron-up"}
              class="w-3.5 h-3.5"
            />
          </button>
        </div>
        <div :if={@bottom_panel_open} class="flex-1 overflow-y-auto p-3">
          <.tab_content
            tab={@active_tab}
            page={@page}
            page_sources={assigns[:page_sources] || []}
            related_pages={assigns[:related_pages] || []}
            page_versions={assigns[:page_versions] || []}
            myself={@myself}
          />
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("switch_brain_tab", %{"tab" => tab}, socket) do
    tab = normalize_tab(tab)
    notify_parent({:load_brain_panel, tab})

    {:noreply, assign(socket, active_tab: tab, bottom_panel_open: true)}
  end

  def handle_event("toggle_bottom_panel", _params, socket) do
    if not socket.assigns.bottom_panel_open do
      notify_parent({:load_brain_panel, socket.assigns.active_tab})
    end

    {:noreply, assign(socket, :bottom_panel_open, !socket.assigns.bottom_panel_open)}
  end

  def handle_event("navigate_to_block", %{"page-id" => page_id}, socket) do
    notify_parent({:open_brain_page, socket.assigns.brain.id, page_id})
    {:noreply, socket}
  end

  def handle_event("open_related_page", %{"brain-id" => brain_id, "page-id" => page_id}, socket) do
    notify_parent({:open_brain_page, brain_id, page_id})
    {:noreply, socket}
  end

  def handle_event("view_version", %{"version-id" => version_id}, socket) do
    notify_parent({:view_brain_version, version_id})
    {:noreply, socket}
  end

  def handle_event("close_version", _params, socket) do
    notify_parent(:close_brain_version)
    {:noreply, socket}
  end

  def handle_event("restore_version", %{"version-id" => version_id}, socket) do
    notify_parent({:restore_brain_version, version_id})
    {:noreply, socket}
  end

  def handle_event("start_editing_title", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_title, true)
     |> assign(:title_value, socket.assigns.page.title)}
  end

  def handle_event("save_title", %{"title" => title}, socket) do
    title = String.trim(title)

    socket =
      if title != "" and title != socket.assigns.page.title do
        notify_parent({:update_page_title, title})
        assign(socket, :editing_title, false)
      else
        assign(socket, :editing_title, false)
      end

    {:noreply, socket}
  end

  def handle_event("save_title", _params, socket) do
    {:noreply, assign(socket, :editing_title, false)}
  end

  def handle_event("title_keydown", %{"key" => "Escape"}, socket) do
    {:noreply, assign(socket, :editing_title, false)}
  end

  def handle_event("title_keydown", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel_editing_title", _params, socket) do
    {:noreply, assign(socket, :editing_title, false)}
  end

  # ============================================================================
  # Drag-drop / paste upload pipeline
  # ============================================================================

  @doc false
  # Called by Phoenix.LiveView with `auto_upload: true` whenever an entry's
  # progress changes. Once an entry is `done?`, we consume it: read the
  # uploaded file, create a Files.File record scoped to the brain's
  # workspace, and insert a `:file` block via the BrainHandlers funnel.
  # The block PubSub broadcast (handled by BrainPageView / ChatLive) takes
  # care of refreshing the editor.
  def handle_drop_progress(:brain_drop, entry, socket) do
    if entry.done? do
      consume_drop_entry(socket, entry)
    end

    {:noreply, socket}
  end

  # Consumes a single completed upload entry. We use `consume_uploaded_entry/3`
  # (not the plural `consume_uploaded_entries/3`) because the progress callback
  # may fire for one entry while others are still in-flight; the plural form
  # raises in that case.
  defp consume_drop_entry(socket, entry) do
    user = socket.assigns[:current_user]
    page = socket.assigns[:page]
    brain = socket.assigns[:brain]

    cond do
      is_nil(user) or is_nil(page) or is_nil(brain) ->
        :ok

      true ->
        upload_opts =
          [actor: user]
          |> maybe_put(:workspace_id, brain.workspace_id)

        result =
          consume_uploaded_entry(socket, entry, fn %{path: path} ->
            case File.read(path) do
              {:ok, content} ->
                case Magus.Files.Upload.create_file_from_upload(
                       content,
                       entry.client_name,
                       entry.client_type,
                       byte_size(content),
                       upload_opts
                     ) do
                  {:ok, file} -> {:ok, {:ok, file.id}}
                  {:error, reason} -> {:ok, {:error, reason}}
                end

              {:error, reason} ->
                {:ok, {:error, {:read_error, reason}}}
            end
          end)

        case result do
          {:ok, file_id} ->
            # Append the file/image link to the page body. The link form
            # (`magus://image/...` vs `magus://file/...`) is decided by
            # the file's `:type` inside `BodyAppender.append_file_by_id`.
            # The `page.body_updated` broadcast triggers the editor reload.
            case Magus.Brain.BodyAppender.append_file_by_id(page, file_id, "", user) do
              {:ok, _updated_page} ->
                :ok

              {:error, reason} ->
                Logger.warning("brain editor drop body append failed",
                  reason: inspect(reason),
                  filename: entry.client_name,
                  size: entry.client_size,
                  file_id: file_id,
                  user_id: user && user.id,
                  page_id: page && page.id,
                  workspace_id: brain && brain.workspace_id
                )

                notify_parent({:flash, :error, gettext("Could not insert file block")})
            end

          {:error, reason} ->
            Logger.warning("brain editor drop upload failed",
              reason: inspect(reason),
              filename: entry.client_name,
              size: entry.client_size,
              user_id: user && user.id,
              page_id: page && page.id,
              workspace_id: brain && brain.workspace_id
            )

            notify_parent({:flash, :error, gettext("File upload failed")})

          _ ->
            :ok
        end

        :ok
    end
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  # ============================================================================
  # Header helpers
  # ============================================================================

  # Renders the breadcrumb ancestors with middle-segment truncation when
  # the path is too long. Returns a list of `{:page, ancestor}` /
  # `:ellipsis` tokens. The page title itself is rendered separately and
  # is not part of this list.
  #
  # Total breadcrumb segments = length(ancestors) + 1 (current page).
  # We truncate when the total exceeds 5 segments, i.e. ancestors > 4.
  # Output shape: `[first, :ellipsis, second_last, last]` plus the page
  # title renders as: `Brain > A > … > Y > Z`.
  defp truncate_breadcrumbs(ancestors) when is_list(ancestors) do
    if length(ancestors) > 4 do
      [first | _] = ancestors
      last_two = Enum.take(ancestors, -2)
      [{:page, first}, :ellipsis] ++ Enum.map(last_two, fn anc -> {:page, anc} end)
    else
      Enum.map(ancestors, fn anc -> {:page, anc} end)
    end
  end

  # Tooltip listing the omitted breadcrumb segments. Empty string when
  # the breadcrumb wasn't truncated; the title attribute is benign in
  # that case so callers don't need to branch.
  defp breadcrumb_ellipsis_title(ancestors) when is_list(ancestors) do
    if length(ancestors) > 4 do
      omitted = ancestors |> Enum.drop(1) |> Enum.drop(-2)
      omitted |> Enum.map(&(&1.title || "Untitled")) |> Enum.join(" / ")
    else
      ""
    end
  end

  # ============================================================================
  # Tab Content
  # ============================================================================

  defp tab_content(%{tab: :outline} = assigns) do
    headings = parse_body_headings(assigns.page.body)
    assigns = assign(assigns, :headings, headings)

    ~H"""
    <ul
      :if={@headings != []}
      id={"brain-outline-#{@page.id}"}
      phx-hook=".OutlineScroll"
      class="space-y-1"
    >
      <li
        :for={{heading, index} <- Enum.with_index(@headings)}
        class="text-xs text-base-content/70 truncate cursor-pointer hover:text-primary"
        style={"padding-left: #{(heading.level - 1) * 0.75}rem"}
        data-heading-index={index}
      >
        {heading.text}
      </li>
    </ul>
    <p :if={@headings == []} class="text-xs text-base-content/40 text-center py-4">
      {gettext("No headings yet")}
    </p>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".OutlineScroll">
      export default {
        mounted() {
          this.onClick = (e) => {
            const li = e.target.closest("[data-heading-index]")
            if (!li) return
            const index = parseInt(li.dataset.headingIndex, 10)
            const pane = this.el.closest("[data-brain-pane]")
            if (!pane) return
            const headings = pane.querySelectorAll(
              ".ProseMirror h1, .ProseMirror h2, .ProseMirror h3, .ProseMirror h4, .ProseMirror h5, .ProseMirror h6"
            )
            const target = headings[index]
            if (!target) return
            target.scrollIntoView({ behavior: "smooth", block: "start" })
            if (this._flashTimer) clearTimeout(this._flashTimer)
            target.style.transition = "background-color 0.4s ease"
            target.style.backgroundColor = "color-mix(in oklab, var(--color-primary) 18%, transparent)"
            this._flashTimer = setTimeout(() => {
              target.style.backgroundColor = ""
              target.style.transition = ""
            }, 1100)
          }
          this.el.addEventListener("click", this.onClick)
        },
        destroyed() {
          if (this._flashTimer) clearTimeout(this._flashTimer)
          this.el.removeEventListener("click", this.onClick)
        }
      }
    </script>
    """
  end

  # Phase C: sources are page-scoped (via `PageSource`). Each row links out
  # to the external URL in a new browser tab.
  defp tab_content(%{tab: :sources} = assigns) do
    ~H"""
    <div class="space-y-1">
      <.source_row :for={source <- @page_sources} source={source} />
      <div :if={@page_sources == []} class="text-xs text-base-content/40">
        {gettext("No sources on this page yet")}
      </div>
    </div>
    """
  end

  # Phase C5: each entry is a backlink (a page that mentions the current
  # page via `[[Page Name]]`). `:link_text` is what the source body wrote;
  # `:current_title` is the live title. If the page was renamed after the
  # link was authored, surface the drift inline.
  defp tab_content(%{tab: :related} = assigns) do
    ~H"""
    <div class="space-y-1">
      <div
        :for={entry <- @related_pages}
        class="flex items-center gap-2 text-xs cursor-pointer hover:bg-base-200/30 rounded px-1 py-0.5"
        phx-click="open_related_page"
        phx-value-brain-id={entry.brain_id}
        phx-value-page-id={entry.page_id}
        phx-target={@myself}
        data-brain-related-id={entry.page_id}
      >
        <div class="w-1.5 h-1.5 rounded-full bg-base-content/30" />
        <span class="text-base-content truncate flex-1">{entry.current_title}</span>
        <span
          :if={entry.drifted?}
          class="text-base-content/40 italic"
          title={gettext("Linked as \"%{title}\"", title: entry.link_text)}
          data-link-drift
        >
          ↻
        </span>
      </div>
      <div :if={@related_pages == []} class="text-xs text-base-content/40">
        {gettext("No related pages yet")}
      </div>
    </div>
    """
  end

  # Phase C: Activity is this page's version history. Each row opens the
  # version viewer overlay (handled by the parent via `notify_parent`).
  defp tab_content(%{tab: :activity} = assigns) do
    ~H"""
    <div class="space-y-1">
      <button
        :for={entry <- @page_versions}
        type="button"
        phx-click="view_version"
        phx-value-version-id={entry.version_id}
        phx-target={@myself}
        data-brain-version-id={entry.version_id}
        class="w-full flex items-start gap-2 text-xs py-0.5 cursor-pointer hover:bg-base-200/30 rounded px-1 text-left"
      >
        <span class="text-base-content/30 whitespace-nowrap">
          {format_relative_time(entry.inserted_at)}
        </span>
        <div class="flex-1 min-w-0 truncate">
          <span class="text-base-content/50">{action_label(entry.action_name)}</span>
          <span :if={entry.preview != ""} class="text-base-content/30 mx-0.5">&middot;</span>
          <span :if={entry.preview != ""} class="text-base-content/80">{entry.preview}</span>
        </div>
      </button>
      <div :if={@page_versions == []} class="text-xs text-base-content/40">
        {gettext("No history yet")}
      </div>
    </div>
    """
  end

  attr :viewing_version, :map, required: true
  attr :myself, :any, required: true

  defp version_overlay(assigns) do
    ~H"""
    <div
      data-brain-version-overlay
      class="absolute inset-0 z-20 bg-base-100 flex flex-col"
    >
      <div class="flex items-center justify-between gap-3 px-4 py-2 border-b border-base-300/50 bg-base-200/40">
        <div class="flex flex-col min-w-0">
          <span class="text-sm font-medium text-base-content truncate">
            {gettext("Version from %{time}", time: format_version_time(@viewing_version.inserted_at))}
          </span>
          <span class="text-xs text-base-content/50">
            {action_label(@viewing_version.action_name)}
          </span>
        </div>
        <div class="flex items-center gap-1">
          <button
            :if={not @viewing_version.is_latest?}
            type="button"
            phx-click="restore_version"
            phx-value-version-id={@viewing_version.version_id}
            phx-target={@myself}
            data-brain-version-restore
            class="wb-pill-btn"
          >
            <.icon name="lucide-history" class="w-4 h-4" />
            <span>{gettext("Restore this version")}</span>
          </button>
          <button
            type="button"
            phx-click="close_version"
            phx-target={@myself}
            data-brain-version-close
            class="wb-pill-btn wb-pill-btn-square"
            title={gettext("Back")}
          >
            <.icon name="lucide-x" class="w-4 h-4" />
          </button>
        </div>
      </div>
      <div class="flex-1 overflow-y-auto p-4 font-mono text-xs leading-relaxed">
        <.diff_row :for={row <- @viewing_version.diff_rows} row={row} />
        <p
          :if={@viewing_version.diff_rows == []}
          class="text-base-content/40 font-sans"
        >
          {gettext("No content changes in this version.")}
        </p>
      </div>
    </div>
    """
  end

  attr :row, :map, required: true

  defp diff_row(%{row: %{kind: :gap}} = assigns) do
    ~H"""
    <div class="text-center text-base-content/30 py-1 select-none">
      {ngettext("%{count} unchanged line", "%{count} unchanged lines", @row.count)}
    </div>
    """
  end

  defp diff_row(%{row: %{kind: kind}} = assigns) when kind in [:context, :del, :ins] do
    assigns =
      assigns
      |> assign(:line_class, diff_line_class(kind))
      |> assign(:gutter, diff_gutter(kind))

    ~H"""
    <div class={["flex gap-2 whitespace-pre-wrap break-words", @line_class]}>
      <span class="select-none text-base-content/30 w-3 shrink-0">{@gutter}</span>
      <span class="flex-1">
        <.diff_token :for={token <- @row.tokens} token={token} />
      </span>
    </div>
    """
  end

  defp diff_row(assigns), do: ~H""

  attr :token, :any, required: true

  defp diff_token(%{token: {:same, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"<span>{@text}</span>"
  end

  defp diff_token(%{token: {:removed, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H|<span class="bg-error/30 rounded-sm">{@text}</span>|
  end

  defp diff_token(%{token: {:added, text}} = assigns) do
    assigns = assign(assigns, :text, text)

    ~H|<span class="bg-success/30 rounded-sm">{@text}</span>|
  end

  defp diff_line_class(:context), do: "text-base-content/70"
  defp diff_line_class(:del), do: "bg-error/10 text-base-content"
  defp diff_line_class(:ins), do: "bg-success/10 text-base-content"

  defp diff_gutter(:context), do: ""
  defp diff_gutter(:del), do: "-"
  defp diff_gutter(:ins), do: "+"

  defp format_version_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp format_version_time(_), do: ""

  attr :source, :map, required: true

  defp source_row(%{source: %{url: url}} = assigns) when is_binary(url) and url != "" do
    ~H"""
    <a
      href={@source.url}
      target="_blank"
      rel="noopener noreferrer"
      data-brain-source-id={@source.id}
      class="flex items-center gap-2 text-xs hover:bg-base-200/30 rounded px-1 py-0.5"
    >
      <span>{source_tab_icon(@source.source_type)}</span>
      <span class="text-base-content truncate flex-1">
        {@source.title || @source.url || gettext("Untitled")}
      </span>
      <span class="text-base-content/40">{source_type_label(@source.source_type)}</span>
    </a>
    """
  end

  defp source_row(assigns) do
    ~H"""
    <div
      data-brain-source-id={@source.id}
      class="flex items-center gap-2 text-xs rounded px-1 py-0.5"
    >
      <span>{source_tab_icon(@source.source_type)}</span>
      <span class="text-base-content truncate flex-1">
        {@source.title || gettext("Untitled")}
      </span>
      <span class="text-base-content/40">{source_type_label(@source.source_type)}</span>
    </div>
    """
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp normalize_tab(tab) when tab in [:outline, :sources, :related, :activity], do: tab
  defp normalize_tab("outline"), do: :outline
  defp normalize_tab("sources"), do: :sources
  defp normalize_tab("related"), do: :related
  defp normalize_tab("activity"), do: :activity
  defp normalize_tab(_), do: :outline

  defp tab_label(:outline), do: gettext("Outline")
  defp tab_label(:sources), do: gettext("Sources")
  defp tab_label(:related), do: gettext("Related")
  defp tab_label(:activity), do: gettext("Activity")

  # Atom variants drive the Phase C `Source.source_type` enum (see
  # `Magus.Brain.Source`); the string variants stay as a fallback for any
  # caller passing the raw value from a legacy block.
  defp source_tab_icon(:pdf), do: "📄"
  defp source_tab_icon("pdf"), do: "📄"
  defp source_tab_icon(:paper), do: "📄"
  defp source_tab_icon(:book), do: "📚"
  defp source_tab_icon(:video), do: "🎥"
  defp source_tab_icon(:feed), do: "📰"
  defp source_tab_icon("file"), do: "📁"
  defp source_tab_icon("api"), do: "🔌"
  defp source_tab_icon(_), do: "🔗"

  defp source_type_label(nil), do: "web"
  defp source_type_label(type) when is_atom(type), do: Atom.to_string(type)
  defp source_type_label(type) when is_binary(type), do: type

  # Page.Version `:version_action_name` → short human label. New actions
  # added in later phases (e.g. `:undo`, `:restore`) will surface as their
  # raw atom string until added here.
  defp action_label(:update_body), do: gettext("edited")
  defp action_label(:update_title), do: gettext("renamed")
  defp action_label(:create), do: gettext("created")
  defp action_label(:create_as_external_agent), do: gettext("created")
  defp action_label(:move_to_parent), do: gettext("moved")
  defp action_label(:soft_delete), do: gettext("trashed")
  defp action_label(:restore), do: gettext("restored")
  defp action_label(:destroy), do: gettext("deleted")
  defp action_label(action) when is_atom(action), do: Atom.to_string(action)
  defp action_label(_), do: ""

  defp format_relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff < 60 -> gettext("now")
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86400 -> "#{div(diff, 3600)}h"
      true -> "#{div(diff, 86400)}d"
    end
  end

  # Extracts ATX-style headings (`#`..`######`) from a markdown body for
  # the outline tab. Returns `[%{level: 1..6, text: binary}]` in document
  # order. Lines inside fenced code blocks are skipped so a `## ` sample
  # inside a ` ``` ` block isn't promoted to an outline entry. Setext
  # headings (`===`/`---` underlines) aren't surfaced; the editor emits
  # ATX exclusively.
  defp parse_body_headings(nil), do: []
  defp parse_body_headings(""), do: []

  defp parse_body_headings(body) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.reduce({[], false}, fn line, {acc, in_fence?} ->
      cond do
        String.starts_with?(line, "```") ->
          {acc, not in_fence?}

        in_fence? ->
          {acc, in_fence?}

        true ->
          case Regex.run(~r/^(\#{1,6})\s+(.+?)\s*$/, line) do
            [_, hashes, text] ->
              {[%{level: String.length(hashes), text: String.trim(text)} | acc], in_fence?}

            _ ->
              {acc, in_fence?}
          end
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.reject(&(&1.text == ""))
  end

  defp parse_body_headings(_), do: []

  # Read-only header pill showing the brain's workspace visibility.
  # Personal brains (no workspace_id) render the personal icon; brains in
  # a workspace render as either "Shared with workspace" or "Personal in
  # workspace" based on the `is_shared_to_workspace` calc.
  attr :brain, :map, required: true

  defp visibility_pill(%{brain: %{workspace_id: nil}} = assigns) do
    ~H"""
    <div
      class="inline-flex items-center gap-1.5 px-1.5 text-xs text-base-content/60"
      data-visibility="personal"
      title={gettext("Only you can see this brain")}
    >
      <.icon name="lucide-user" class="w-4 h-4" />
      <span>{gettext("Personal")}</span>
    </div>
    """
  end

  defp visibility_pill(%{brain: %{is_shared_to_workspace: true}} = assigns) do
    ~H"""
    <div
      class="inline-flex items-center gap-1.5 px-1.5 text-xs text-base-content/60"
      data-visibility="workspace"
      title={gettext("Shared with everyone in this workspace")}
    >
      <.icon name="lucide-users" class="w-4 h-4" />
      <span>{gettext("Workspace")}</span>
    </div>
    """
  end

  defp visibility_pill(assigns) do
    ~H"""
    <div
      class="inline-flex items-center gap-1.5 px-1.5 text-xs text-base-content/60"
      data-visibility="personal-in-workspace"
      title={gettext("Only you can see this brain")}
    >
      <.icon name="lucide-user" class="w-4 h-4" />
      <span>{gettext("Personal")}</span>
    </div>
    """
  end
end
