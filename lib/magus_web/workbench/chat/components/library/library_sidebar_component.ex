defmodule MagusWeb.ChatLive.Components.Library.LibrarySidebarComponent do
  @moduledoc """
  LiveComponent for the Library sidebar showing prompts.

  Handles:
  - Prompt management (create, edit, delete, publish)
  - System prompt activation for conversations

  Uses `phx-target={@myself}` for all events.
  Notifies parent via `notify_parent/1` for system prompt activation.
  """
  use MagusWeb, :live_component
  use MagusWeb.Live.Shared.ComponentUtils

  import MagusWeb.ChatLive.Components.Library.UIHelpers
  import MagusWeb.ChatLive.Components.Library.CollapsibleBox

  require Logger

  @prompt_types [:system, :user]

  def render(assigns) do
    # Determine which sections to show based on visible_section prop
    # nil means show all sections, otherwise show only the specified section
    visible_section = assigns[:visible_section]
    floating_mode = assigns[:floating_mode] || false
    chromeless = floating_mode and not is_nil(visible_section)

    assigns =
      assigns
      |> assign(:visible_section, visible_section)
      |> assign(:floating_mode, floating_mode)
      |> assign(:chromeless, chromeless)

    ~H"""
    <div class={[
      "h-full w-full flex flex-col overflow-x-hidden bg-wb-surface",
      @chromeless && "min-h-0",
      !@chromeless && "overflow-y-auto p-2 gap-2"
    ]}>
      <%!-- Prompts Section --%>
      <.collapsible_box
        :if={@visible_section == nil || @visible_section == :prompts}
        id="prompts-section"
        title={gettext("Prompts")}
        icon="lucide-puzzle"
        expanded={@visible_section == :prompts || @prompts_expanded}
        myself={@myself}
        toggle_event="toggle_prompts"
        always_expanded={@visible_section == :prompts}
        floating_mode={@floating_mode}
        chromeless={@chromeless}
        action_icon="lucide-plus"
        action_event="show_prompt_form"
        action_title={gettext("New Prompt")}
        secondary_action_icon={if @conversation_id, do: "lucide-sparkles"}
        secondary_action_event="create_prompt_from_conversation"
        secondary_action_title={gettext("Create prompt from conversation")}
        secondary_action_label={gettext("From chat")}
        badge={length(@prompts)}
      >
        <%!-- Active System Prompt Indicator --%>
        <div
          :if={@active_system_prompt}
          class="mb-3 p-2 bg-primary/10 rounded-lg border border-primary/30"
        >
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <.icon name="lucide-id-card" class="w-5 h-5 text-primary" />
              <span class="text-sm font-medium">{@active_system_prompt.name}</span>
            </div>
            <button
              type="button"
              class="icon-btn text-error"
              phx-click="deactivate_system_prompt"
              phx-target={@myself}
              title={gettext("Deactivate")}
            >
              <.icon name="lucide-x" class="w-4 h-4" />
            </button>
          </div>
        </div>

        <%!-- Tabs --%>
        <div role="tablist" class="tabs tabs-lift tabs-sm mb-3">
          <button
            type="button"
            role="tab"
            class={"tab #{if @prompts_tab == :mine, do: "tab-active"}"}
            phx-click="set_prompts_tab"
            phx-value-tab="mine"
            phx-target={@myself}
          >
            {gettext("My Prompts")}
          </button>
          <button
            type="button"
            role="tab"
            class={"tab #{if @prompts_tab == :favorites, do: "tab-active"} flex gap-2"}
            phx-click="set_prompts_tab"
            phx-value-tab="favorites"
            phx-target={@myself}
          >
            <.icon name="lucide-heart" class="w-4 h-4" /> {gettext("Favorites")}
          </button>
        </div>

        <%!-- Search & Filter --%>
        <div class="flex gap-2 mb-3">
          <form
            phx-change="search_prompts"
            phx-target={@myself}
            phx-submit="search_prompts"
            class="flex-1"
          >
            <.search_input value={@prompt_search} placeholder="Search..." size="sm" debounce="200" />
          </form>
          <form phx-change="filter_prompts" phx-target={@myself}>
            <select name="type" class="select select-bordered select-sm bg-base-100 w-24">
              <option value="all" selected={@prompt_type_filter == :all}>All</option>
              <option :for={type <- @prompt_types} value={type} selected={@prompt_type_filter == type}>
                {prompt_type_label(type)}
              </option>
            </select>
          </form>
        </div>

        <%!-- Prompts List --%>
        <div
          id="prompts-list"
          class="space-y-1"
          phx-hook="DraggablePrompts"
          data-type="prompts"
        >
          <%= if @prompts_tab == :mine do %>
            <.prompt_item
              :for={prompt <- @prompts}
              prompt={prompt}
              myself={@myself}
              compact={false}
              active={@active_system_prompt && @active_system_prompt.id == prompt.id}
            />
            <div :if={@prompts == []} class="text-center text-base-content/50 py-4 text-sm">
              {gettext("No prompts yet")}
            </div>
          <% else %>
            <.prompt_item
              :for={prompt <- @favorite_prompts}
              prompt={prompt}
              myself={@myself}
              compact={false}
              active={@active_system_prompt && @active_system_prompt.id == prompt.id}
            />
            <div :if={@favorite_prompts == []} class="text-center text-base-content/50 py-4 text-sm">
              {gettext("No favorite prompts yet")}
            </div>
          <% end %>
        </div>
      </.collapsible_box>

      <%!-- Jobs Section (only show when in a conversation and has jobs) --%>
      <.collapsible_box
        :if={
          (@visible_section == nil || @visible_section == :jobs) && @conversation_id &&
            length(@jobs) > 0
        }
        id="jobs-section"
        title={gettext("Jobs")}
        icon="lucide-clock"
        expanded={@visible_section == :jobs || @jobs_expanded}
        myself={@myself}
        toggle_event="toggle_jobs"
        always_expanded={@visible_section == :jobs}
        floating_mode={@floating_mode}
        chromeless={@chromeless}
        badge={length(@jobs)}
        description={gettext("Automated tasks scheduled to run in this conversation.")}
      >
        <div class="space-y-2">
          <.job_item :for={job <- @jobs} job={job} myself={@myself} />
        </div>

        <.link navigate={~p"/jobs"} class="text-xs text-primary hover:underline block mt-3">
          {gettext("Manage all jobs")} &rarr;
        </.link>
      </.collapsible_box>

      <%!-- Brains Section (admin only) --%>
      <.collapsible_box
        :if={@visible_section == nil || @visible_section == :brains}
        id="brains-section"
        title={gettext("Brains")}
        icon="lucide-brain"
        expanded={@visible_section == :brains || @brains_expanded}
        myself={@myself}
        toggle_event="toggle_brains"
        always_expanded={@visible_section == :brains}
        floating_mode={@floating_mode}
        chromeless={@chromeless}
        action_icon="lucide-plus"
        action_event="create_brain"
        action_title={gettext("New Brain")}
        badge={length(@brains)}
      >
        <.live_component
          module={MagusWeb.ChatLive.Components.Brain.BrainSidebarComponent}
          id="brain-sidebar"
          current_user={@current_user}
          active_page_id={@active_page_id}
          workspace_id={assigns[:workspace_id]}
        />
      </.collapsible_box>

      <%!-- Drafts Section --%>
      <.collapsible_box
        :if={(@visible_section == nil || @visible_section == :drafts) && @conversation_id}
        id="drafts-section"
        title={gettext("Drafts")}
        icon="lucide-file-text"
        expanded={@visible_section == :drafts || @drafts_expanded}
        myself={@myself}
        toggle_event="toggle_drafts"
        always_expanded={@visible_section == :drafts}
        floating_mode={@floating_mode}
        chromeless={@chromeless}
        badge={length(@conversation_drafts)}
      >
        <.live_component
          module={MagusWeb.ChatLive.Components.Library.DraftsSidebarComponent}
          id="drafts-sidebar"
          drafts={@conversation_drafts}
          active_draft_id={@active_draft_id}
          current_user={@current_user}
          conversation_id={@conversation_id}
        />
      </.collapsible_box>

      <%!-- Files Section --%>
      <.collapsible_box
        :if={@visible_section == nil || @visible_section == :files}
        id="files-section"
        title={gettext("Files")}
        icon="lucide-database"
        expanded={@visible_section == :files || @files_expanded}
        myself={@myself}
        toggle_event="toggle_files"
        always_expanded={@visible_section == :files}
        floating_mode={@floating_mode}
        chromeless={@chromeless}
      >
        <.live_component
          module={MagusWeb.ChatLive.Components.Library.FilesSidebarComponent}
          id="files-sidebar"
          current_user={@current_user}
          conversation_id={@conversation_id}
          folder_id={@folder_id}
          workspace_id={assigns[:workspace_id]}
        />
      </.collapsible_box>

      <%!-- Settings Section --%>
      <.collapsible_box
        :if={@visible_section == nil || @visible_section == :settings}
        id="settings-section"
        title={gettext("Settings")}
        icon="lucide-settings"
        expanded={@visible_section == :settings || @settings_expanded}
        myself={@myself}
        toggle_event="toggle_settings"
        always_expanded={@visible_section == :settings}
        floating_mode={@floating_mode}
        chromeless={@chromeless}
      >
        <.live_component
          module={MagusWeb.ChatLive.Components.Library.SettingsSidebarComponent}
          id="settings-sidebar"
          current_user={@current_user}
          conversation_id={@conversation_id}
        />
      </.collapsible_box>
    </div>
    """
  end

  def mount(socket) do
    {:ok,
     socket
     # Card states will be loaded from user preferences in update/2
     |> assign(:prompts_expanded, false)
     |> assign(:settings_expanded, false)
     |> assign(:files_expanded, false)
     |> assign(:prompts_tab, :mine)
     |> assign(:prompt_type_filter, :all)
     |> assign(:prompt_types, @prompt_types)
     |> assign(:prompt_search, "")
     |> assign(:prompts, [])
     |> assign(:favorite_prompts, [])
     |> assign(:available_tags, [])
     |> assign(:active_system_prompt, nil)
     |> assign(:models, [])
     # Jobs
     |> assign(:jobs_expanded, false)
     |> assign(:jobs, [])
     # Drafts
     |> assign(:drafts_expanded, false)
     |> assign(:conversation_drafts, [])
     |> assign(:active_draft_id, nil)
     # Brains
     |> assign(:brains_expanded, false)
     |> assign(:brains, [])
     |> assign(:active_page_id, nil)}
  end

  def update(%{action: :prompt_form_closed}, socket) do
    {:ok, load_prompts(socket)}
  end

  def update(assigns, socket) do
    socket =
      socket
      |> assign(assigns)
      |> maybe_assign_active_system_prompt()
      |> load_tags()
      |> load_models()
      |> load_prompts()
      |> load_favorites()
      |> load_jobs()
      |> load_brains()

    {:ok, socket}
  end

  defp maybe_assign_active_system_prompt(socket) do
    if Map.has_key?(socket.assigns, :active_system_prompt) do
      socket
    else
      assign(socket, :active_system_prompt, nil)
    end
  end

  # Toggle event handlers - only one section can be open at a time
  def handle_event("toggle_prompts", _, socket) do
    new_state = !socket.assigns.prompts_expanded
    {:noreply, toggle_section(socket, :prompts_expanded, new_state)}
  end

  def handle_event("toggle_files", _, socket) do
    new_state = !socket.assigns.files_expanded
    {:noreply, toggle_section(socket, :files_expanded, new_state)}
  end

  def handle_event("toggle_settings", _, socket) do
    new_state = !socket.assigns.settings_expanded
    {:noreply, toggle_section(socket, :settings_expanded, new_state)}
  end

  def handle_event("toggle_drafts", _, socket) do
    new_state = !socket.assigns.drafts_expanded
    {:noreply, toggle_section(socket, :drafts_expanded, new_state)}
  end

  def handle_event("toggle_jobs", _, socket) do
    new_state = !socket.assigns.jobs_expanded
    {:noreply, toggle_section(socket, :jobs_expanded, new_state)}
  end

  def handle_event("toggle_brains", _, socket) do
    new_state = !socket.assigns.brains_expanded
    {:noreply, toggle_section(socket, :brains_expanded, new_state)}
  end

  def handle_event("create_brain", _, socket) do
    notify_parent(:create_brain)
    {:noreply, socket}
  end

  def handle_event("set_prompts_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :prompts_tab, String.to_existing_atom(tab))}
  end

  def handle_event("search_prompts", %{"query" => query}, socket) do
    {:noreply, socket |> assign(:prompt_search, query) |> load_prompts()}
  end

  def handle_event("filter_prompts", %{"type" => value}, socket) do
    filter = if value == "all", do: :all, else: String.to_existing_atom(value)
    {:noreply, socket |> assign(:prompt_type_filter, filter) |> load_prompts()}
  end

  def handle_event("show_prompt_form", _, socket) do
    notify_parent({:show_prompt_form, nil})
    {:noreply, socket}
  end

  def handle_event("create_prompt_from_conversation", _, socket) do
    if socket.assigns.conversation_id do
      notify_parent({:create_prompt_from_conversation, socket.assigns.conversation_id})
    end

    {:noreply, socket}
  end

  def handle_event("hide_prompt_form", _, socket) do
    notify_parent(:hide_prompt_form)
    {:noreply, socket}
  end

  def handle_event("edit_prompt", %{"id" => id}, socket) do
    prompt = Magus.Library.get_prompt!(id, actor: socket.assigns.current_user)
    notify_parent({:show_prompt_form, prompt})
    {:noreply, socket}
  end

  def handle_event("delete_prompt", %{"id" => id}, socket) do
    prompt = Magus.Library.get_prompt!(id, actor: socket.assigns.current_user)
    Magus.Library.destroy_prompt!(prompt, actor: socket.assigns.current_user)
    {:noreply, load_prompts(socket)}
  end

  def handle_event("publish_prompt", %{"id" => id}, socket) do
    prompt = Magus.Library.get_prompt!(id, actor: socket.assigns.current_user)

    if prompt.is_public do
      Magus.Library.unpublish_prompt!(prompt, actor: socket.assigns.current_user)
    else
      Magus.Library.publish_prompt!(prompt, %{is_public: true},
        actor: socket.assigns.current_user
      )
    end

    {:noreply, load_prompts(socket)}
  end

  # System prompt activation handlers
  def handle_event("activate_system_prompt", %{"id" => id}, socket) do
    prompt = Magus.Library.get_prompt!(id, actor: socket.assigns.current_user, load: [:model])
    Magus.Library.increment_prompt_use_count(prompt, authorize?: false)
    notify_parent({:activate_system_prompt, prompt})
    {:noreply, assign(socket, :active_system_prompt, prompt)}
  end

  def handle_event("deactivate_system_prompt", _, socket) do
    notify_parent(:deactivate_system_prompt)
    notify_parent(:close_prompt_detail)

    {:noreply, assign(socket, :active_system_prompt, nil)}
  end

  def handle_event("insert_prompt_content", %{"id" => id}, socket) do
    prompt = Magus.Library.get_prompt!(id, actor: socket.assigns.current_user)
    Magus.Library.increment_prompt_use_count(prompt, authorize?: false)
    notify_parent({:insert_prompt_content, prompt})
    {:noreply, socket}
  end

  def handle_event("view_prompt_detail", %{"id" => id}, socket) do
    prompt = Magus.Library.get_prompt!(id, actor: socket.assigns.current_user, load: [:model])
    notify_parent({:view_prompt_detail, prompt})
    {:noreply, socket}
  end

  def handle_event("close_prompt_detail", _, socket) do
    notify_parent(:close_prompt_detail)
    {:noreply, socket}
  end

  def handle_event("activate_and_close", %{"id" => id}, socket) do
    prompt = Magus.Library.get_prompt!(id, actor: socket.assigns.current_user, load: [:model])
    Magus.Library.increment_prompt_use_count(prompt, authorize?: false)
    notify_parent({:activate_system_prompt, prompt})
    notify_parent(:close_prompt_detail)

    {:noreply, assign(socket, :active_system_prompt, prompt)}
  end

  def handle_event("insert_and_close", %{"id" => id}, socket) do
    prompt = Magus.Library.get_prompt!(id, actor: socket.assigns.current_user)
    Magus.Library.increment_prompt_use_count(prompt, authorize?: false)
    notify_parent({:insert_prompt_content, prompt})
    notify_parent(:close_prompt_detail)
    {:noreply, socket}
  end

  # Job event handlers
  def handle_event("pause_job", %{"id" => id}, socket) do
    with {:ok, job} <- Magus.Workflows.get_job(id, actor: socket.assigns.current_user),
         {:ok, _} <- Magus.Workflows.pause_job(job, actor: socket.assigns.current_user) do
      {:noreply, load_jobs(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("resume_job", %{"id" => id}, socket) do
    with {:ok, job} <- Magus.Workflows.get_job(id, actor: socket.assigns.current_user),
         {:ok, _} <- Magus.Workflows.resume_job(job, actor: socket.assigns.current_user) do
      {:noreply, load_jobs(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("stop_job", %{"id" => id}, socket) do
    with {:ok, job} <- Magus.Workflows.get_job(id, actor: socket.assigns.current_user),
         {:ok, _} <- Magus.Workflows.stop_job(job, actor: socket.assigns.current_user) do
      {:noreply, load_jobs(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  # Private functions
  defp load_tags(socket) do
    assign(socket, :available_tags, Magus.Library.list_tags!())
  end

  defp load_models(socket) do
    models = Magus.Chat.list_active_models!(authorize?: false)
    assign(socket, :models, models)
  end

  defp load_prompts(socket) do
    prompts =
      case socket.assigns.prompt_type_filter do
        :all ->
          Magus.Library.my_prompts!(actor: socket.assigns.current_user, load: [:tags, :model])

        type ->
          Magus.Library.my_prompts_by_type!(type,
            actor: socket.assigns.current_user,
            load: [:tags, :model]
          )
      end

    prompts =
      case socket.assigns.prompt_search do
        "" ->
          prompts

        query ->
          q = String.downcase(query)

          Enum.filter(prompts, fn b ->
            String.contains?(String.downcase(b.name), q) ||
              String.contains?(String.downcase(b.content), q)
          end)
      end

    assign(socket, :prompts, prompts)
  end

  defp load_favorites(socket) do
    user = socket.assigns.current_user

    favorite_prompts =
      try do
        Magus.Library.my_favorite_prompts!(actor: user, load: [:user, :model])
      rescue
        e ->
          Logger.warning("Failed to load favorite prompts: #{inspect(e)}")
          []
      end

    assign(socket, :favorite_prompts, favorite_prompts)
  end

  defp load_jobs(socket) do
    case socket.assigns.conversation_id do
      nil ->
        assign(socket, :jobs, [])

      conversation_id ->
        jobs =
          Magus.Workflows.list_jobs_for_conversation!(conversation_id,
            actor: socket.assigns.current_user
          )

        assign(socket, :jobs, jobs)
    end
  end

  defp load_brains(socket) do
    user = socket.assigns.current_user

    brains =
      case socket.assigns[:workspace_id] do
        nil -> Magus.Brain.list_brains!(actor: user)
        ws_id -> Magus.Brain.list_brains_for_workspace!(ws_id, actor: user)
      end

    assign(socket, :brains, brains)
  end

  # Toggle a section, closing all others when opening
  defp toggle_section(socket, section, new_state) do
    all_sections = [
      :prompts_expanded,
      :drafts_expanded,
      :jobs_expanded,
      :files_expanded,
      :settings_expanded,
      :brains_expanded
    ]

    if new_state do
      # Opening a section: close all others
      Enum.reduce(all_sections, socket, fn s, acc ->
        assign(acc, s, s == section)
      end)
    else
      # Closing a section: just close it
      assign(socket, section, false)
    end
  end
end
