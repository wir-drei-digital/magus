defmodule MagusWeb.Workbench.Modes.AgentsModeNav do
  @moduledoc """
  Agents mode nav.

  Personal workspace (workspace_id is nil): a single list of the actor's
  no-workspace agents.

  Regular workspace: workspace-scoped agents split into Shared and Personal
  via the `is_shared_to_workspace` calculation. The actor's no-workspace
  agents never appear here.

  Clicking an agent emits `select_detail` to the parent LV; agents don't
  open as tabs in v1.
  """
  use MagusWeb, :live_component

  import MagusWeb.Workbench.Layout.ResourceTree.SectionHeader

  alias Magus.Agents

  @impl true
  def update(%{images_loaded: %{shared: shared, personal: personal}}, socket) do
    {:ok,
     socket
     |> assign(:shared_agents, shared)
     |> assign(:personal_agents, personal)
     |> assign(:images_loaded?, true)}
  end

  def update(assigns, socket) do
    user = assigns.current_user
    workspace_id = assigns[:workspace_id]
    nav_filter = assigns[:nav_filter] || :all
    base = load_base_agents(workspace_id, user)
    {shared, personal} = split_by_share(base, workspace_id)

    in_workspace? = not is_nil(workspace_id)
    {show_shared?, show_personal?} = visible_sections(in_workspace?, nav_filter)

    socket =
      socket
      |> assign(assigns)
      |> assign(:in_workspace?, in_workspace?)
      |> assign(:show_shared?, show_shared?)
      |> assign(:show_personal?, show_personal?)
      |> assign(:shared_agents, shared)
      |> assign(:personal_agents, personal)

    {:ok, maybe_load_images_async(socket, base, workspace_id, user)}
  end

  defp maybe_load_images_async(socket, [], _workspace_id, _user), do: socket

  defp maybe_load_images_async(socket, base, workspace_id, user) do
    if socket.assigns[:images_loaded?] do
      socket
    else
      myself = socket.assigns.myself

      Task.start(fn ->
        loaded = Ash.load!(base, [:image_url], actor: user)
        {shared, personal} = split_by_share(loaded, workspace_id)
        Phoenix.LiveView.send_update(myself, images_loaded: %{shared: shared, personal: personal})
      end)

      socket
    end
  end

  defp visible_sections(false, _filter), do: {false, true}
  defp visible_sections(true, :all), do: {true, true}
  defp visible_sections(true, :shared), do: {true, false}
  defp visible_sections(true, :personal), do: {false, true}
  defp visible_sections(true, _other), do: {true, true}

  defp load_base_agents(_workspace_id, nil), do: []

  defp load_base_agents(nil, user) do
    Agents.list_personal_agents!(actor: user)
  end

  defp load_base_agents(workspace_id, user) do
    Agents.list_workspace_agents!(workspace_id, actor: user)
  end

  defp split_by_share(agents, nil), do: {[], agents}

  defp split_by_share(agents, _workspace_id) do
    Enum.split_with(agents, &(&1.is_shared_to_workspace == true))
  end

  @impl true
  def render(assigns) do
    ~H"""
    <nav
      class="flex flex-col h-full overflow-y-auto"
      aria-label="Agents"
      data-testid="agents-mode-nav"
    >
      <%!-- Shared section (workspace mode only) --%>
      <section :if={@show_shared?} class="flex flex-col mt-2">
        <.section_header label="Shared" />
        <ul class="px-1 space-y-0.5">
          <.empty_state :if={@shared_agents == []} message="No shared agents" />
          <.agent_card :for={agent <- @shared_agents} agent={agent} />
        </ul>
      </section>

      <%!-- Personal section --%>
      <section :if={@show_personal?} class={["flex flex-col", @in_workspace? && "mt-2"]}>
        <.section_header :if={@in_workspace?} label="Personal" />
        <.section_header :if={not @in_workspace?} label="Agents" />
        <ul class="px-1 space-y-0.5">
          <.empty_state
            :if={@personal_agents == []}
            message={
              if @in_workspace?,
                do: "No personal agents in this workspace",
                else: "No agents yet"
            }
          />
          <.agent_card :for={agent <- @personal_agents} agent={agent} />
        </ul>
      </section>
    </nav>
    """
  end

  attr :agent, :map, required: true

  defp agent_card(assigns) do
    ~H"""
    <li class="list-none">
      <button
        type="button"
        phx-click="select_detail"
        phx-value-type="agent"
        phx-value-id={@agent.id}
        data-agent-id={@agent.id}
        class="w-full flex items-center gap-3 px-2 py-2 rounded-md hover:bg-wb-hover text-left transition-colors"
      >
        <.agent_avatar agent={@agent} />
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-1.5 min-w-0">
            <span class="text-sm font-medium text-wb-text truncate">{@agent.name}</span>
            <span class={[
              "w-1.5 h-1.5 rounded-full shrink-0",
              if(@agent.is_paused, do: "bg-wb-text-dim", else: "bg-success")
            ]} />
          </div>
          <p :if={@agent.description} class="text-xs text-wb-text-dim line-clamp-2">
            {@agent.description}
          </p>
        </div>
        <span class="text-[10px] text-wb-text-dim shrink-0">
          {agent_relative_time(@agent)}
        </span>
      </button>
    </li>
    """
  end

  attr :agent, :map, required: true

  defp agent_avatar(assigns) do
    ~H"""
    <%= cond do %>
      <% @agent.icon -> %>
        <div class="w-8 h-8 rounded-md bg-wb-surface-2 flex items-center justify-center text-base shrink-0">
          <span>{@agent.icon}</span>
        </div>
      <% is_binary(@agent.image_url) -> %>
        <img src={@agent.image_url} alt="" class="w-8 h-8 rounded-md object-cover shrink-0" />
      <% true -> %>
        <div class="w-8 h-8 rounded-md bg-wb-surface-2 flex items-center justify-center shrink-0">
          <.icon name="lucide-bot" class="w-4 h-4 text-wb-text-muted" />
        </div>
    <% end %>
    """
  end

  defp agent_relative_time(agent) do
    case Map.get(agent, :heartbeat_at) || Map.get(agent, :updated_at) do
      %DateTime{} = dt -> relative(dt)
      _ -> ""
    end
  end

  defp relative(dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "now"
      diff < 3600 -> "#{div(diff, 60)}m"
      diff < 86_400 -> "#{div(diff, 3600)}h"
      diff < 604_800 -> "#{div(diff, 86_400)}d"
      true -> "#{div(diff, 604_800)}w"
    end
  end
end
