defmodule MagusWeb.ChatLive.Components.Draft.DraftPaneComponent do
  @moduledoc """
  Live component for rendering the draft document pane.

  Uses TipTap Phoenix for rich-text editing with ProseMirror JSON storage.
  Includes a header with title, version badge, status, and controls.
  The TipTap bubble menu provides formatting and refine/ask actions inline.
  Supports a "History" tab to browse and restore past versions via ash_paper_trail.

  The component is purely presentational — all business logic (refine, restore, etc.)
  is delegated to the parent LiveView via `notify_parent/1`.
  """

  use MagusWeb, :live_component

  @impl true
  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> assign_new(:active_tab, fn -> :document end)
      |> assign_new(:versions, fn -> [] end)
      |> assign_new(:preview_version, fn -> nil end)

    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"draft-pane-#{@id}"}
      phx-hook=".DownloadFile"
      class="flex flex-col h-full border-l border-base-300 bg-wb-surface relative"
    >
      <script :type={Phoenix.LiveView.ColocatedHook} name=".DownloadFile">
        export default {
          mounted() {
            this.handleEvent("download_file", ({filename, mime, content}) => {
              const blob = new Blob([content], {type: mime || "application/octet-stream"});
              const url = URL.createObjectURL(blob);
              const a = document.createElement("a");
              a.href = url;
              a.download = filename || "download";
              document.body.appendChild(a);
              a.click();
              document.body.removeChild(a);
              setTimeout(() => URL.revokeObjectURL(url), 0);
            });
          }
        }
      </script>
      <%!-- Header --%>
      <div class="flex items-center justify-between px-4 py-2 min-h-14 border-b border-wb-border bg-wb-bg backdrop-blur-sm relative z-10">
        <div class="flex items-center gap-2 min-w-0 pr-2">
          <.icon name="lucide-file-text" class="w-4 h-4 text-primary flex-shrink-0" />
          <h3 class="font-medium text-sm truncate">{@draft.title}</h3>
        </div>
        <div class="flex items-center gap-1">
          <button
            type="button"
            phx-click="review_draft"
            phx-target={@myself}
            class="wb-pill-btn"
            title={gettext("Review draft")}
          >
            <.icon name="lucide-scan-search" class="w-4 h-4" />
            <span class="hidden sm:inline">{gettext("Review")}</span>
          </button>

          <div class="dropdown dropdown-end">
            <label tabindex="0" class="wb-pill-btn cursor-pointer">
              <.icon name="lucide-download" class="w-4 h-4" />
              <span class="hidden sm:inline">{gettext("Export")}</span>
              <.icon name="lucide-chevron-down" class="w-3 h-3" />
            </label>
            <ul
              tabindex="0"
              class="dropdown-content z-50 menu p-2 shadow-lg bg-wb-surface border border-wb-border-strong rounded-box w-52"
            >
              <li>
                <button phx-click={
                  JS.push("export_draft", target: @myself, value: %{format: "pdf"})
                  |> JS.dispatch("click", to: "body")
                }>
                  PDF
                </button>
              </li>
              <li>
                <button phx-click={
                  JS.push("export_draft", target: @myself, value: %{format: "docx"})
                  |> JS.dispatch("click", to: "body")
                }>
                  Word (DOCX)
                </button>
              </li>
              <li>
                <button phx-click={
                  JS.push("export_draft", target: @myself, value: %{format: "latex"})
                  |> JS.dispatch("click", to: "body")
                }>
                  LaTeX (fancy PDF)
                </button>
              </li>
              <li>
                <button phx-click={
                  JS.push("export_draft", target: @myself, value: %{format: "markdown"})
                  |> JS.dispatch("click", to: "body")
                }>
                  Markdown
                </button>
              </li>
            </ul>
          </div>

          <button
            type="button"
            phx-click="copy_draft"
            phx-target={@myself}
            class="wb-pill-btn wb-pill-btn-square"
            title={gettext("Copy to clipboard")}
          >
            <.icon name="lucide-copy" class="w-4 h-4" />
          </button>

          <button
            type="button"
            phx-click="close_draft_pane"
            class="wb-pill-btn wb-pill-btn-square"
            title={gettext("Close draft pane")}
          >
            <.icon name="lucide-x" class="w-4 h-4" />
          </button>
        </div>
      </div>

      <%!-- Tab Bar --%>
      <div class="flex items-center gap-1 px-4 border-b border-base-300 bg-base-100">
        <button
          type="button"
          phx-click="switch_tab"
          phx-value-tab="document"
          phx-target={@myself}
          class={[tab_class(@active_tab == :document), "cursor-pointer"]}
        >
          {gettext("Document")}
        </button>
        <button
          type="button"
          phx-click="switch_tab"
          phx-value-tab="history"
          phx-target={@myself}
          class={[tab_class(@active_tab == :history), "cursor-pointer"]}
        >
          {gettext("History")}
          <span class="badge badge-xs badge-ghost font-mono ml-1">v{@draft.version}</span>
        </button>
      </div>

      <%!-- Document Tab: TipTap Editor --%>
      <div
        :if={@active_tab == :document && !@preview_version}
        class="flex-1 overflow-y-auto"
      >
        <TiptapPhoenix.Component.tiptap_editor
          id={"draft-editor-#{@draft.id}"}
          content={@draft.content}
          section_key="draft"
          placeholder={gettext("Start writing...")}
          class="prose prose-sm max-w-none px-6 py-4"
        />
      </div>

      <%!-- Version Preview (shown when previewing a version from history) --%>
      <div :if={@preview_version} class="flex-1 overflow-y-auto relative">
        <div class="sticky top-0 z-10 flex items-center justify-between px-4 py-2 bg-warning/10 border-b border-warning/30">
          <span class="text-xs text-base-content">
            {gettext("Viewing version from %{date}",
              date: format_datetime(@preview_version.version_inserted_at)
            )}
          </span>
          <div class="flex gap-1">
            <button
              type="button"
              phx-click="restore_version"
              phx-value-id={@preview_version.id}
              phx-target={@myself}
              class="btn btn-warning btn-xs cursor-pointer"
            >
              {gettext("Restore")}
            </button>
            <button
              type="button"
              phx-click="close_preview"
              phx-target={@myself}
              class="btn btn-ghost btn-xs cursor-pointer"
            >
              {gettext("Back to current")}
            </button>
          </div>
        </div>
        <div class="px-6 py-4">
          <div
            id={"version-preview-#{@preview_version.id}"}
            class="prose prose-sm max-w-none"
            phx-hook="RichContent"
            phx-update="ignore"
          >
            {render_rich_preview(version_content(@preview_version))}
          </div>
        </div>
      </div>

      <%!-- History Tab --%>
      <div :if={@active_tab == :history && !@preview_version} class="flex-1 overflow-y-auto">
        <div
          :if={@versions == []}
          class="flex items-center justify-center h-32 text-base-content/50 text-sm"
        >
          {gettext("No version history yet")}
        </div>
        <div
          :for={version <- @versions}
          class="px-4 py-3 border-b border-base-200 hover:bg-base-200/50 transition-colors"
        >
          <div class="flex items-center justify-between">
            <div class="min-w-0">
              <span class="text-sm font-medium">{humanize_action(version.version_action_name)}</span>
              <span class="text-xs text-base-content/50 ml-2">
                {format_datetime(version.version_inserted_at)}
              </span>
            </div>
            <div class="flex gap-1 flex-shrink-0">
              <button
                type="button"
                phx-click="preview_version"
                phx-value-id={version.id}
                phx-target={@myself}
                class="btn btn-ghost btn-xs cursor-pointer"
              >
                {gettext("View")}
              </button>
              <button
                type="button"
                phx-click="restore_version"
                phx-value-id={version.id}
                phx-target={@myself}
                class="btn btn-ghost btn-xs cursor-pointer"
              >
                {gettext("Restore")}
              </button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Refining overlay --%>
      <div
        :if={@refining}
        class="absolute inset-0 z-20 bg-base-300/50 backdrop-blur-[1px] flex items-center justify-center"
      >
        <div class="flex flex-col items-center gap-2">
          <span class="loading loading-spinner loading-md text-primary"></span>
          <span class="text-sm text-base-content/70 font-medium">{gettext("Refining...")}</span>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => "history"}, socket) do
    versions = load_versions(socket.assigns.draft.id, socket.assigns.current_user)
    {:noreply, assign(socket, active_tab: :history, versions: versions, preview_version: nil)}
  end

  def handle_event("switch_tab", %{"tab" => _}, socket) do
    {:noreply, assign(socket, active_tab: :document, preview_version: nil)}
  end

  def handle_event("preview_version", %{"id" => version_id}, socket) do
    version = Enum.find(socket.assigns.versions, &(to_string(&1.id) == version_id))

    {:noreply, assign(socket, preview_version: version)}
  end

  def handle_event("close_preview", _params, socket) do
    {:noreply, assign(socket, preview_version: nil)}
  end

  def handle_event("restore_version", %{"id" => version_id}, socket) do
    notify_parent({:restore_draft_version, %{version_id: version_id}})
    {:noreply, assign(socket, preview_version: nil, active_tab: :document)}
  end

  def handle_event("copy_draft", _params, socket) do
    text =
      Magus.Drafts.ProseMirrorConverter.to_markdown(socket.assigns.draft.content)

    {:noreply, push_event(socket, "copy_to_clipboard", %{text: text})}
  end

  def handle_event("review_draft", _params, socket) do
    notify_parent(
      {:review_draft,
       %{
         draft_id: to_string(socket.assigns.draft.id),
         conversation_id: to_string(socket.assigns.conversation_id)
       }}
    )

    {:noreply, socket}
  end

  def handle_event("export_draft", %{"format" => format}, socket) do
    case validate_export_format(format) do
      {:ok, :markdown} ->
        # Markdown is just the on-disk representation of the draft already, so
        # we skip the agent round-trip and stream the file straight to the
        # browser via the colocated `DownloadFile` hook.
        draft = socket.assigns.draft
        markdown = Magus.Drafts.ProseMirrorConverter.to_markdown(draft.content)
        filename = build_export_filename(draft.title, "md")

        {:noreply,
         push_event(socket, "download_file", %{
           filename: filename,
           mime: "text/markdown",
           content: markdown
         })}

      {:ok, format_atom} ->
        notify_parent(
          {:export_draft,
           %{
             draft_id: to_string(socket.assigns.draft.id),
             conversation_id: to_string(socket.assigns.conversation_id),
             export_format: format_atom
           }}
        )

        {:noreply, socket}

      :error ->
        {:noreply, socket}
    end
  end

  defp load_versions(draft_id, user) do
    case Magus.Drafts.list_draft_versions(draft_id, actor: user) do
      {:ok, [_current | older]} -> older
      {:ok, _} -> []
      {:error, _} -> []
    end
  end

  defp render_rich_preview(content) do
    content
    |> TiptapPhoenix.Renderer.render()
    |> convert_mermaid_blocks()
    |> convert_math_blocks()
    |> Phoenix.HTML.raw()
  end

  defp convert_mermaid_blocks(html) do
    String.replace(
      html,
      ~r/<pre><code class="language-mermaid">(.*?)<\/code><\/pre>/s,
      "<pre class=\"mermaid\">\\1</pre>"
    )
  end

  defp convert_math_blocks(html) do
    Regex.replace(
      ~r/<pre><code class="language-math">(.*?)<\/code><\/pre>/s,
      html,
      fn _, latex ->
        # Unescape HTML entities from the renderer, then re-escape for the attribute
        raw_latex = html_unescape(latex)

        escaped =
          raw_latex |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

        ~s(<div class="katex-block" data-latex="#{escaped}"></div>)
      end
    )
  end

  defp html_unescape(text) do
    text
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", ~s("))
    |> String.replace("&#39;", "'")
  end

  defp version_content(version) do
    # Paper trail changes are stored as JSON — content is now a ProseMirror JSON map
    get_in(version.changes, ["content"]) || TiptapPhoenix.default_doc()
  end

  defp humanize_action(:create), do: gettext("Created")
  defp humanize_action(:update_content), do: gettext("Updated content")
  defp humanize_action(:update_content_json), do: gettext("Updated content")
  defp humanize_action(:update_title), do: gettext("Updated title")
  defp humanize_action(:replace_text), do: gettext("Replaced text")
  defp humanize_action(:restore_version), do: gettext("Restored version")
  defp humanize_action(name) when is_atom(name), do: Phoenix.Naming.humanize(name)
  defp humanize_action(name) when is_binary(name), do: Phoenix.Naming.humanize(name)
  defp humanize_action(_), do: gettext("Changed")

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%b %d, %H:%M")
  end

  defp tab_class(true), do: "px-3 py-2 text-sm font-medium text-primary border-b-2 border-primary"

  defp tab_class(false),
    do:
      "px-3 py-2 text-sm text-base-content/60 hover:text-base-content border-b-2 border-transparent"

  defp validate_export_format("pdf"), do: {:ok, :pdf}
  defp validate_export_format("docx"), do: {:ok, :docx}
  defp validate_export_format("latex"), do: {:ok, :latex}
  defp validate_export_format("markdown"), do: {:ok, :markdown}
  defp validate_export_format(_), do: :error

  defp build_export_filename(title, ext) do
    base =
      (title || "")
      |> String.trim()
      |> String.replace(~r/[^\w\s\-.]+/u, "")
      |> String.replace(~r/\s+/u, "-")
      |> String.slice(0, 80)

    base = if base == "", do: "draft", else: base
    "#{base}.#{ext}"
  end

  defp notify_parent(msg), do: send(self(), {__MODULE__, msg})
end
