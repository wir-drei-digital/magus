defmodule MagusWeb.Workbench.Tab.TabContainer do
  @moduledoc """
  Per-tab container LiveView. Mounted via `live_render` from WorkbenchLive
  (one per open tab, all sticky). Dispatches on primary type to the right
  resource LV; renders a companion slot (Phase 3B).
  """
  use MagusWeb, :live_view

  alias MagusWeb.Workbench.Resources.BrainPageView
  alias MagusWeb.Workbench.Resources.ConversationView
  alias MagusWeb.Workbench.Signals

  on_mount({MagusWeb.LiveUserAuth, :current_user})

  @impl true
  def mount(_params, session, socket) do
    tab = session["tab"]

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Magus.PubSub, Signals.tab_topic(tab["id"]))
    end

    {:ok,
     socket
     |> assign(:tab, tab)
     |> assign(:workspace_id, session["workspace_id"])
     |> assign(:user_id, session["user_id"])
     |> assign(:agent_edit, session["agent_edit"])
     |> assign(:prompt_edit, session["prompt_edit"])
     |> assign(:shell_topic, Signals.workbench_user_topic(session["user_id"]))}
  end

  @impl true
  def handle_info({:workbench_companion, {:open, spec}}, socket) do
    tab = Map.put(socket.assigns.tab, "companion", spec)
    notify_workbench_companion_changed(tab, socket)
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_info({:workbench_companion, :close}, socket) do
    tab = Map.put(socket.assigns.tab, "companion", nil)
    notify_workbench_companion_changed(tab, socket)
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  defp notify_workbench_companion_changed(tab, socket) do
    Phoenix.PubSub.broadcast(
      Magus.PubSub,
      socket.assigns.shell_topic,
      {:workbench_tab_companion_changed, tab["id"], tab["companion"]}
    )
  end

  @impl true
  def render(assigns) do
    has_companion? = not is_nil(assigns.tab["companion"])
    assigns = assign(assigns, :has_companion?, has_companion?)

    ~H"""
    <div
      class={
        [
          # Always grid so the inner section gets a constrained height the
          # conversation/brain views can use as their `h-full` reference.
          # Layout cases (md+):
          #   no companion:    [primary]
          #   with companion:  [primary | companion]
          # Mobile: always single cell. Companion takes over (primary hidden
          # via `hidden md:block`).
          "tab-container h-full grid",
          @has_companion? && "md:grid-cols-2"
        ]
      }
      data-tab-container
      data-tab-id={@tab["id"]}
      data-user-id={@user_id}
      data-mobile-companion-active={to_string(@has_companion?)}
    >
      <section class={[
        "primary-slot min-h-0 overflow-hidden",
        @has_companion? && "hidden md:block"
      ]}>
        {render_primary(assigns)}
      </section>

      <section
        :if={@has_companion?}
        class="companion-slot border-l border-wb-border min-h-0 overflow-hidden"
        data-companion-type={@tab["companion"]["type"]}
        data-companion-id={@tab["companion"]["id"]}
      >
        {render_companion(assigns)}
      </section>
    </div>
    """
  end

  defp render_primary(%{tab: %{"primary" => %{"type" => "agent", "id" => id}}} = assigns) do
    assigns = assign(assigns, :agent_id, id)

    ~H"""
    {live_render(@socket, MagusWeb.Workbench.Resources.AgentView,
      id: "agent-view-#{@agent_id}",
      session:
        Map.merge(
          %{"agent_id" => @agent_id, "user_id" => @user_id, "tab_id" => @tab["id"]},
          @agent_edit || %{}
        )
    )}
    """
  end

  defp render_primary(%{tab: %{"primary" => %{"type" => "brain_page", "id" => id}}} = assigns) do
    assigns =
      assigns
      |> assign(:page_id, id)
      |> assign(:has_companion, not is_nil(assigns.tab["companion"]))

    ~H"""
    {live_render(@socket, BrainPageView,
      id: "brain-page-#{@page_id}",
      session: %{
        "page_id" => @page_id,
        "user_id" => @user_id,
        "tab_id" => @tab["id"],
        "role" => "primary",
        "has_companion" => @has_companion
      }
    )}
    """
  end

  defp render_primary(%{tab: %{"primary" => %{"type" => "conversation", "id" => id}}} = assigns) do
    assigns = assign(assigns, :conversation_id, id)

    ~H"""
    {live_render(@socket, ConversationView,
      id: "conversation-#{@conversation_id}",
      session: %{
        "conversation_id" => @conversation_id,
        "user_id" => @user_id,
        "tab_id" => @tab["id"],
        "workspace_id" => @workspace_id
      }
    )}
    """
  end

  defp render_primary(%{tab: %{"primary" => %{"type" => "file", "id" => id}}} = assigns) do
    assigns = assign(assigns, :file_id, id)

    ~H"""
    {live_render(@socket, MagusWeb.Workbench.Resources.FileView,
      id: "file-view-#{@file_id}",
      sticky: true,
      session: %{"file_id" => @file_id, "user_id" => @user_id, "tab_id" => @tab["id"]}
    )}
    """
  end

  defp render_primary(%{tab: %{"primary" => %{"type" => "prompt", "id" => id}}} = assigns) do
    assigns = assign(assigns, :prompt_id, id)

    ~H"""
    {live_render(@socket, MagusWeb.Workbench.Resources.PromptView,
      id: "prompt-view-#{@prompt_id}",
      sticky: true,
      session:
        Map.merge(
          %{"prompt_id" => @prompt_id, "user_id" => @user_id, "tab_id" => @tab["id"]},
          @prompt_edit || %{}
        )
    )}
    """
  end

  defp render_primary(%{tab: %{"primary" => %{"type" => "file_browser"} = primary}} = assigns) do
    assigns = assign(assigns, :primary, primary)

    ~H"""
    {live_render(@socket, MagusWeb.Workbench.Resources.FileBrowserView,
      id: "file-browser-#{@tab["id"]}",
      sticky: true,
      session: %{
        "scope" => @primary["scope"],
        "id" => @primary["id"],
        "filters" => @primary["filters"] || %{},
        "sort" => @primary["sort"] || "updated_at:desc",
        "q" => @primary["q"] || "",
        "user_id" => @user_id,
        "workspace_id" => @workspace_id,
        "tab_id" => @tab["id"]
      }
    )}
    """
  end

  defp render_primary(%{tab: %{"primary" => %{"type" => type, "id" => id}}} = assigns) do
    assigns = assign(assigns, :type, type) |> assign(:id, id)

    ~H"""
    <div class="h-full flex flex-col items-center justify-center text-wb-text-muted gap-2 p-8">
      <.icon name="lucide-circle-help" class="w-10 h-10 text-wb-text-dim" />
      <h3 class="text-sm font-medium">No renderer for "{@type}"</h3>
      <p class="text-xs">Resource id: {@id}</p>
    </div>
    """
  end

  defp render_companion(%{tab: %{"companion" => %{"type" => type, "id" => _id}}} = assigns) do
    case type do
      "draft" -> render_draft(assigns)
      "thread" -> render_thread(assigns)
      "service" -> render_service(assigns)
      "pdf" -> render_pdf(assigns)
      "spreadsheet" -> render_spreadsheet(assigns)
      "brain_page" -> render_brain_page(assigns)
      "conversation" -> render_conversation_companion(assigns)
      _ -> render_fallback(assigns)
    end
  end

  defp render_conversation_companion(
         %{tab: %{"companion" => %{"id" => conversation_id} = spec}} = assigns
       ) do
    # Pull `initial_brain_selection` from the spec so the companion
    # ConversationView can stash it on first mount. BrainPageView embeds
    # this when it opens a chat companion in response to a bubble-menu
    # Ask, since broadcasting the selection on the tab topic would race
    # the new LV's mount → subscribe.
    assigns =
      assigns
      |> assign(:conversation_id, conversation_id)
      |> assign(:initial_brain_selection, Map.get(spec, "initial_brain_selection"))

    ~H"""
    {live_render(@socket, ConversationView,
      id: "companion-conversation-#{@conversation_id}",
      session: %{
        "conversation_id" => @conversation_id,
        "user_id" => @user_id,
        "tab_id" => @tab["id"],
        "role" => "companion",
        "initial_brain_selection" => @initial_brain_selection
      }
    )}
    """
  end

  defp render_draft(%{tab: %{"companion" => %{"id" => draft_id}}} = assigns) do
    assigns =
      assigns
      |> assign(:draft_id, draft_id)
      |> assign(:conversation_id, primary_conversation_id(assigns.tab))

    ~H"""
    {live_render(@socket, MagusWeb.Workbench.Resources.Companions.DraftCompanion,
      id: "companion-draft-#{@draft_id}",
      session: %{
        "draft_id" => @draft_id,
        "conversation_id" => @conversation_id,
        "user_id" => @user_id,
        "tab_id" => @tab["id"]
      }
    )}
    """
  end

  defp render_thread(%{tab: %{"companion" => %{"id" => thread_id}}} = assigns) do
    assigns =
      assigns
      |> assign(:thread_id, thread_id)
      |> assign(:conversation_id, primary_conversation_id(assigns.tab))

    ~H"""
    {live_render(@socket, MagusWeb.Workbench.Resources.Companions.ThreadCompanion,
      id: "companion-thread-#{@thread_id}",
      session: %{
        "thread_id" => @thread_id,
        "conversation_id" => @conversation_id,
        "user_id" => @user_id,
        "tab_id" => @tab["id"]
      }
    )}
    """
  end

  defp render_service(%{tab: %{"companion" => %{"id" => conversation_id}}} = assigns) do
    assigns = assign(assigns, :conversation_id, conversation_id)

    ~H"""
    {live_render(@socket, MagusWeb.Workbench.Resources.Companions.ServiceCompanion,
      id: "companion-service-#{@conversation_id}",
      session: %{
        "conversation_id" => @conversation_id,
        "user_id" => @user_id,
        "tab_id" => @tab["id"]
      }
    )}
    """
  end

  defp render_pdf(
         %{tab: %{"companion" => %{"id" => file_id, "name" => filename, "url" => url}}} = assigns
       ) do
    assigns =
      assigns
      |> assign(:file_id, file_id)
      |> assign(:pdf_filename, filename)
      |> assign(:pdf_url, url)
      |> assign(:conversation_id, primary_conversation_id(assigns.tab))

    ~H"""
    {live_render(@socket, MagusWeb.Workbench.Resources.Companions.PdfCompanion,
      id: "companion-pdf-#{@file_id}",
      session: %{
        "file_id" => @file_id,
        "filename" => @pdf_filename,
        "url" => @pdf_url,
        "conversation_id" => @conversation_id,
        "user_id" => @user_id,
        "tab_id" => @tab["id"]
      }
    )}
    """
  end

  defp render_pdf(assigns) do
    ~H"""
    <div class="p-4 text-sm text-wb-text-muted">PDF companion: missing url or name.</div>
    """
  end

  defp render_spreadsheet(%{tab: %{"companion" => %{"id" => file_id}}} = assigns) do
    assigns = assign(assigns, :file_id, file_id)

    ~H"""
    {live_render(@socket, MagusWeb.Workbench.Resources.Companions.SpreadsheetCompanion,
      id: "companion-spreadsheet-#{@file_id}",
      session: %{
        "file_id" => @file_id,
        "user_id" => @user_id,
        "tab_id" => @tab["id"]
      }
    )}
    """
  end

  defp render_brain_page(%{tab: %{"companion" => %{"id" => page_id}}} = assigns) do
    assigns = assign(assigns, :page_id, page_id)

    ~H"""
    {live_render(@socket, BrainPageView,
      id: "companion-brain-page-#{@page_id}",
      session: %{
        "page_id" => @page_id,
        "user_id" => @user_id,
        "tab_id" => @tab["id"],
        "role" => "companion"
      }
    )}
    """
  end

  defp primary_conversation_id(%{"primary" => %{"type" => "conversation", "id" => "new"}}),
    do: nil

  defp primary_conversation_id(%{"primary" => %{"type" => "conversation", "id" => id}}), do: id
  defp primary_conversation_id(_), do: nil

  defp render_fallback(%{tab: %{"companion" => %{"type" => type, "id" => id}}} = assigns) do
    assigns = assign(assigns, :type, type) |> assign(:id, id)

    ~H"""
    <div
      data-companion-fallback={@type}
      class="p-4 text-sm text-wb-text-muted"
    >
      Companion ({@type}): {@id} — LV not yet wired
    </div>
    """
  end
end
