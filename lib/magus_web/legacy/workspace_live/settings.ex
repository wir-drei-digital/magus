defmodule MagusWeb.WorkspaceLive.Settings do
  @moduledoc """
  Workspace settings page for owners to manage workspace configuration.
  Renders General settings; Members and Usage are sibling detail views in the
  workbench (see `Magus_web/workbench/detail/`).
  """
  use MagusWeb, :live_view

  require Logger

  alias MagusWeb.Layouts

  on_mount {MagusWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(%{"slug" => slug}, _session, socket) do
    current_user = socket.assigns.current_user
    socket = init_assigns(socket, slug, current_user)
    {:ok, socket}
  end

  @doc """
  Public init hook used by WorkspaceSettingsView (workbench detail view).
  Loads the workspace by slug and applies all assigns. On access error,
  assigns an :access_error flag instead of redirecting (the detail view
  wrapper handles redirection).
  """
  def init_assigns(socket, slug, actor) do
    case Magus.Workspaces.get_workspace_by_slug(slug, actor: actor) do
      {:ok, workspace} ->
        workspace = Ash.load!(workspace, [:members, :default_agent], actor: actor)
        member = Enum.find(workspace.members, &(&1.user_id == actor.id))

        if member && member.role == :admin do
          if connected?(socket) do
            Phoenix.PubSub.subscribe(Magus.PubSub, "workspaces:#{workspace.id}")
          end

          form =
            to_form(
              %{"name" => workspace.name, "is_active" => workspace.is_active},
              as: "workspace"
            )

          agents =
            case Magus.Agents.list_workspace_agents(workspace.id, actor: actor) do
              {:ok, ws_agents} -> Enum.filter(ws_agents, & &1.is_shared_to_workspace)
              _ -> []
            end

          active_members = Enum.filter(workspace.members, & &1.is_active)

          socket
          |> assign(:page_title, gettext("Workspace Settings"))
          |> assign(:workspace, workspace)
          |> assign(:form, form)
          |> assign(:custom_agents, agents)
          |> assign(:active_members, active_members)
          |> assign(:access_error, nil)
          |> assign(:show_delete_modal, false)
          |> assign(:typed_workspace_name, "")
        else
          socket
          |> put_flash(:error, gettext("Only workspace owners can access settings."))
          |> push_navigate(to: ~p"/chat")
        end

      {:error, _} ->
        socket
        |> put_flash(:error, gettext("Workspace not found."))
        |> push_navigate(to: ~p"/chat")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_user={@current_user}
      show_sidebar={false}
      bg_class="bg-spectral"
    >
      <div class="min-h-full">
        <div class="max-w-3xl mx-auto p-4 md:p-8">
          {render_settings_section(assigns)}
        </div>
      </div>
    </Layouts.app>
    """
  end

  @doc """
  Renders the workspace settings page body (no Layouts.app wrapper).
  Used by WorkspaceSettingsView (workbench detail view).
  """
  def render_settings_section(assigns) do
    ~H"""
    <%!-- Page header --%>
    <div class="flex items-center gap-3 mb-6">
      <div class="flex items-center justify-center w-10 h-10 rounded-lg bg-primary/10 text-primary font-bold">
        {String.first(@workspace.name)}
      </div>
      <div>
        <h1 class="text-2xl font-bold text-base-content">{@workspace.name}</h1>
        <p class="text-sm text-base-content/60">{gettext("Workspace Settings")}</p>
      </div>
    </div>

    <div class="space-y-6">
      <%!-- Settings Card --%>
      <div class="bg-base-200 border border-base-300 rounded-xl p-5 shadow-sm">
        <h2 class="text-lg font-semibold text-base-content mb-4">
          {gettext("Settings")}
        </h2>
        <.form for={@form} phx-submit="save_settings" class="space-y-4">
          <.input
            field={@form[:name]}
            type="text"
            label={gettext("Workspace Name")}
            required
          />
          <div class="flex items-center gap-3">
            <.input
              field={@form[:is_active]}
              type="checkbox"
              label={gettext("Workspace Active")}
            />
          </div>
          <button type="submit" class="btn btn-primary btn-sm">
            {gettext("Save Changes")}
          </button>
        </.form>
      </div>

      <%!-- Default Agent Card --%>
      <div class="bg-base-200 border border-base-300 rounded-xl p-5 shadow-sm">
        <h2 class="text-lg font-semibold text-base-content mb-1">
          {gettext("Default Agent")}
        </h2>
        <p class="text-sm text-base-content/60 mb-4">
          {gettext("Set a default custom agent for new workspace conversations.")}
        </p>
        <select
          name="agent_id"
          class="select select-bordered w-full"
          phx-change="set_default_agent"
        >
          <option value="" selected={is_nil(@workspace.default_agent_id)}>
            {gettext("None (use default)")}
          </option>
          <option
            :for={agent <- @custom_agents}
            value={agent.id}
            selected={@workspace.default_agent_id == agent.id}
          >
            {agent.name}
          </option>
        </select>
      </div>

      <%!-- Workspace Info Card --%>
      <div class="bg-base-200 border border-base-300 rounded-xl p-5 shadow-sm">
        <h2 class="text-lg font-semibold text-base-content mb-4">
          {gettext("Workspace Info")}
        </h2>
        <dl class="space-y-3 text-sm">
          <div class="flex justify-between">
            <dt class="text-base-content/60">{gettext("Slug")}</dt>
            <dd class="font-mono">{@workspace.slug}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/60">{gettext("Active Members")}</dt>
            <dd>{length(@active_members)}</dd>
          </div>
        </dl>
      </div>

      <%!-- Danger Zone --%>
      <div class="bg-base-200 border border-error/40 rounded-xl p-5 shadow-sm">
        <h2 class="text-lg font-semibold text-error mb-1">
          {gettext("Danger Zone")}
        </h2>
        <p class="text-sm text-base-content/60 mb-4">
          {gettext(
            "Deleting this workspace removes all members and unlinks shared conversations, files, prompts, agents, and knowledge sources. This action cannot be undone."
          )}
        </p>
        <button
          type="button"
          phx-click="open_delete_modal"
          class="btn btn-error btn-sm"
        >
          {gettext("Delete Workspace")}
        </button>
      </div>
    </div>

    {render_delete_modal(assigns)}
    """
  end

  defp render_delete_modal(%{show_delete_modal: false} = assigns), do: ~H""

  defp render_delete_modal(assigns) do
    matches? = assigns.typed_workspace_name == assigns.workspace.name
    assigns = assign(assigns, :matches?, matches?)

    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-2xl">
        <h2 class="text-xl font-bold mb-4 text-error">
          {gettext("Delete workspace permanently")}
        </h2>

        <p class="mb-2">
          {gettext("This will immediately and permanently delete:")}
        </p>
        <ul class="list-disc pl-6 mb-4 text-sm space-y-1">
          <li>
            {ngettext(
              "%{count} conversation and all messages",
              "%{count} conversations and all messages",
              @delete_summary.conversation_count,
              count: @delete_summary.conversation_count
            )}
          </li>
          <li>
            {@delete_summary.file_count} {gettext("files")}, {@delete_summary.prompt_count} {gettext(
              "prompts"
            )}, {@delete_summary.custom_agent_count} {gettext("custom agents")}, {@delete_summary.knowledge_source_count} {gettext(
              "knowledge sources"
            )}
          </li>
          <li>
            {ngettext(
              "%{count} member's access to this workspace",
              "%{count} members' access to this workspace",
              @delete_summary.member_count,
              count: @delete_summary.member_count
            )}
          </li>
        </ul>

        <p class="text-xs text-base-content/60 mb-4">
          {gettext(
            "Aggregated usage statistics (token counts, costs) are kept for billing reconciliation."
          )}
        </p>

        <p class="text-sm bg-warning/10 p-3 rounded mb-4">
          {gettext("This action cannot be undone.")}
        </p>

        <form
          id="delete-workspace-form"
          phx-change="validate_workspace_name"
          phx-submit="delete_workspace"
        >
          <label class="block text-sm mb-2">
            {gettext("Type the workspace name")}
            <span class="font-mono">{@workspace.name}</span> {gettext("to confirm:")}
          </label>
          <input
            type="text"
            name="confirm_name"
            value={@typed_workspace_name}
            class="input input-bordered w-full mb-4"
            autocomplete="off"
            phx-debounce="100"
          />

          <div class="modal-action">
            <button type="button" phx-click="close_delete_modal" class="btn">
              {gettext("Cancel")}
            </button>
            <button type="submit" disabled={not @matches?} class="btn btn-error">
              {gettext("Delete workspace")}
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  # ============================================================================
  # Event Handlers
  # ============================================================================

  @impl true
  def handle_event("save_settings", %{"workspace" => params}, socket) do
    case Magus.Workspaces.update_workspace(
           socket.assigns.workspace,
           %{
             name: params["name"],
             is_active: params["is_active"] == "true"
           },
           actor: socket.assigns.current_user
         ) do
      {:ok, workspace} ->
        form =
          to_form(%{"name" => workspace.name, "is_active" => workspace.is_active},
            as: "workspace"
          )

        {:noreply,
         socket
         |> assign(:workspace, workspace)
         |> assign(:form, form)
         |> put_flash(:info, gettext("Settings saved."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not save settings."))}
    end
  end

  @impl true
  def handle_event("set_default_agent", %{"agent_id" => agent_id_str}, socket) do
    agent_id = if agent_id_str == "", do: nil, else: agent_id_str

    case Magus.Workspaces.update_workspace(
           socket.assigns.workspace,
           %{default_agent_id: agent_id},
           actor: socket.assigns.current_user
         ) do
      {:ok, workspace} ->
        workspace = Ash.load!(workspace, [:default_agent], actor: socket.assigns.current_user)

        {:noreply,
         socket
         |> assign(:workspace, workspace)
         |> put_flash(:info, gettext("Default agent updated."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update default agent."))}
    end
  end

  @impl true
  def handle_event("open_delete_modal", _params, socket) do
    {:ok, summary} = Magus.Workspaces.WorkspaceDeletion.preflight(socket.assigns.workspace)

    {:noreply,
     socket
     |> assign(:show_delete_modal, true)
     |> assign(:typed_workspace_name, "")
     |> assign(:delete_summary, summary)}
  end

  @impl true
  def handle_event("close_delete_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_delete_modal, false)
     |> assign(:typed_workspace_name, "")}
  end

  @impl true
  def handle_event("validate_workspace_name", %{"confirm_name" => typed}, socket) do
    {:noreply, assign(socket, :typed_workspace_name, typed)}
  end

  @impl true
  def handle_event("delete_workspace", params, socket) do
    typed = Map.get(params, "confirm_name", socket.assigns.typed_workspace_name)
    workspace = socket.assigns.workspace

    if typed == workspace.name do
      case Magus.Workspaces.WorkspaceDeletion.execute(workspace,
             actor: socket.assigns.current_user
           ) do
        :ok ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Workspace deleted."))
           |> push_navigate(to: ~p"/chat")}

        {:error, error} ->
          Logger.error("Workspace deletion failed for #{workspace.id}: #{inspect(error)}")

          {:noreply,
           socket
           |> assign(:show_delete_modal, false)
           |> put_flash(:error, gettext("Could not delete workspace."))}
      end
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:workspace_deactivated, _workspace_id}, socket) do
    {:noreply,
     socket
     |> put_flash(:error, gettext("This workspace has been deactivated."))
     |> push_navigate(to: ~p"/chat")}
  end
end
