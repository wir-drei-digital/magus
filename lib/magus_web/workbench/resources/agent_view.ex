defmodule MagusWeb.Workbench.Resources.AgentView do
  @moduledoc """
  Agent detail/edit view rendered in the workbench shell's main area when the
  user is in Agents mode and has selected an agent.

  Session:
    - `"agent_id"` — UUID of the custom agent
    - `"user_id"` — UUID of the current user
    - `"edit"` — `"true"` to start in edit mode (optional)
    - `"section"` — initial edit section, e.g. `"tools"` (optional)

  This is always a nested (child) LiveView — it cannot use handle_params.
  Edit/section state is driven by:
    1. Session on initial mount (from WorkbenchLive passing URL params)
    2. send_update from WorkbenchLive when URL params change while tab is open
    3. Internal phx-click section switching handled within this LV

  Edit sections: general, tools, privacy, knowledge, integrations, automation.
  """
  use MagusWeb, :live_view

  import MagusWeb.AgentsLive.AgentHelpers,
    only: [
      activity_badge_class: 1,
      activity_dot_class: 1,
      activity_type_label: 1,
      relative_time: 1
    ]

  import MagusWeb.Workbench.Components.WorkspaceShareButton

  alias MagusWeb.Workbench.Resources.AgentView.Sections
  alias MagusWeb.Workbench.WorkspaceShare

  @valid_sections ~w(general tools privacy knowledge integrations automation)a
  @activity_limit 20
  @inbox_limit 20

  @impl true
  def mount(_params, session, socket) do
    agent_id = session["agent_id"]
    user_id = session["user_id"]
    edit? = session["edit"] == "true"
    section = parse_section(session["section"])
    tab_id = session["tab_id"]

    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    cond do
      agent_id == "new" ->
        mount_create(socket, user, tab_id)

      true ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Magus.PubSub, "agent-view:#{agent_id}")
          Phoenix.PubSub.subscribe(Magus.PubSub, "agent_activity:#{agent_id}")
        end

        mount_existing(socket, user, agent_id, edit?, section, tab_id)
    end
  end

  defp mount_create(socket, user, tab_id) do
    form =
      AshPhoenix.Form.for_create(Magus.Agents.CustomAgent, :create,
        actor: user,
        params: %{"name" => ""}
      )
      |> Phoenix.Component.to_form()

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:agent, nil)
     |> assign(:agent_id, "new")
     |> assign(:tab_id, tab_id)
     |> assign(:not_found, false)
     |> assign(:create_mode?, true)
     |> assign(:edit?, false)
     |> assign(:edit_section, :general)
     |> assign(:valid_sections, @valid_sections)
     |> assign(:profile_gen_ref, nil)
     |> assign(:activity_logs, [])
     |> assign(:inbox_events, [])
     |> assign(:inbox_pending_count, 0)
     |> assign(:integrations, [])
     |> assign(:create_form, form)}
  end

  defp mount_existing(socket, user, agent_id, edit?, section, tab_id) do
    case Magus.Agents.get_custom_agent(agent_id,
           actor: user,
           load: [:model, :image_model, :video_model, :image_url, :is_shared_to_workspace]
         ) do
      {:ok, agent} ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:agent, agent)
         |> assign(:tab_id, tab_id)
         |> assign(:not_found, false)
         |> assign(:create_mode?, false)
         |> assign(:edit?, edit?)
         |> assign(:edit_section, section)
         |> assign(:valid_sections, @valid_sections)
         |> assign(:profile_gen_ref, nil)
         |> load_overview_data()}

      _ ->
        {:ok,
         socket
         |> assign(:current_user, user)
         |> assign(:agent_id, agent_id)
         |> assign(:tab_id, tab_id)
         |> assign(:not_found, true)
         |> assign(:create_mode?, false)
         |> assign(:edit?, false)
         |> assign(:edit_section, :general)
         |> assign(:valid_sections, @valid_sections)
         |> assign(:profile_gen_ref, nil)
         |> assign(:activity_logs, [])
         |> assign(:inbox_events, [])
         |> assign(:inbox_pending_count, 0)
         |> assign(:integrations, [])}
    end
  end

  defp load_overview_data(socket) do
    user = socket.assigns.current_user
    agent_id = socket.assigns.agent.id

    activity_logs =
      case Magus.Agents.list_agent_activity(agent_id, actor: user) do
        {:ok, logs} -> Enum.take(logs, @activity_limit)
        _ -> []
      end

    inbox_events =
      case Magus.Agents.list_agent_events(agent_id, actor: user) do
        {:ok, events} -> events
        _ -> []
      end

    pending_count =
      Enum.count(inbox_events, &(&1.status in [:pending, :waiting, :processing]))

    integrations =
      case Magus.Integrations.list_agent_integrations(agent_id, actor: user) do
        {:ok, list} -> list
        _ -> []
      end

    socket
    |> assign(:activity_logs, activity_logs)
    |> assign(:inbox_events, Enum.take(inbox_events, @inbox_limit))
    |> assign(:inbox_pending_count, pending_count)
    |> assign(:integrations, integrations)
  end

  defp parse_section(s) when is_binary(s) do
    atom = String.to_existing_atom(s)
    if atom in @valid_sections, do: atom, else: :general
  rescue
    ArgumentError -> :general
  end

  defp parse_section(_), do: :general

  defp section_module(:general), do: Sections.General
  defp section_module(:tools), do: Sections.Tools
  defp section_module(:privacy), do: Sections.Privacy
  defp section_module(:knowledge), do: Sections.Knowledge
  defp section_module(:integrations), do: Sections.Integrations
  defp section_module(:automation), do: Sections.Automation

  @impl true
  def handle_event("set_section", %{"section" => section}, socket) do
    {:noreply, assign(socket, :edit_section, parse_section(section))}
  end

  def handle_event("enter_edit", _params, socket) do
    {:noreply, assign(socket, :edit?, true)}
  end

  def handle_event("exit_edit", _params, socket) do
    {:noreply, assign(socket, :edit?, false)}
  end

  def handle_event("validate_create", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.create_form.source, params)
    {:noreply, assign(socket, :create_form, Phoenix.Component.to_form(form))}
  end

  def handle_event("save_create", %{"form" => params}, socket) do
    user = socket.assigns.current_user

    params =
      case user.current_workspace_id do
        nil -> params
        ws_id -> Map.put(params, "workspace_id", ws_id)
      end

    case AshPhoenix.Form.submit(socket.assigns.create_form.source, params: params) do
      {:ok, agent} ->
        if socket.assigns.tab_id do
          Phoenix.PubSub.broadcast(
            Magus.PubSub,
            "workbench-tabs:#{user.id}",
            {:replace_new_tab_with_agent, socket.assigns.tab_id, agent.id}
          )
        end

        {:noreply,
         socket
         |> put_flash(:info, gettext("Agent created"))
         |> push_navigate(to: ~p"/agents/#{agent.id}?edit=true&section=general")}

      {:error, form} ->
        {:noreply, assign(socket, :create_form, Phoenix.Component.to_form(form))}
    end
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/agents")}
  end

  def handle_event("share_to_workspace", _params, socket) do
    {:noreply, toggle_agent_share(socket, :share)}
  end

  def handle_event("unshare_from_workspace", _params, socket) do
    {:noreply, toggle_agent_share(socket, :unshare)}
  end

  def handle_event("dismiss_event", %{"id" => event_id}, socket) do
    user = socket.assigns.current_user

    with {:ok, event} <- Ash.get(Magus.Agents.AgentInboxEvent, event_id, actor: user),
         {:ok, _event} <-
           Magus.Agents.dismiss_event(event, %{resolution_note: "Dismissed by user"}, actor: user) do
      {:noreply, load_overview_data(socket)}
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div data-agent-view class="h-full flex flex-col">
      <div :if={@not_found} class="flex-1 flex items-center justify-center text-wb-text-muted">
        <p>Agent not found.</p>
      </div>

      <div :if={not @not_found and @create_mode?} class="flex-1 flex flex-col min-h-0">
        {render_create_form(assigns)}
      </div>

      <div :if={not @not_found and not @create_mode?} class="flex-1 flex flex-col min-h-0">
        <%= if @edit? do %>
          <%!-- Edit mode: sub-nav + active section component --%>
          <nav
            class="border-b border-wb-border md:px-4 px-14 py-2 flex gap-1 flex-nowrap flex-shrink-0 overflow-x-auto"
            data-edit-section-nav
          >
            <button
              :for={sec <- @valid_sections}
              type="button"
              phx-click="set_section"
              phx-value-section={sec}
              data-edit-section={sec}
              class={[
                "px-3 py-1 text-sm rounded-md transition-colors shrink-0",
                if(@edit_section == sec,
                  do: "bg-wb-surface-2 text-wb-text font-medium",
                  else: "text-wb-text-muted hover:bg-wb-hover"
                )
              ]}
            >
              {Phoenix.Naming.humanize(sec)}
            </button>
          </nav>

          <div class="flex-1 overflow-y-auto">
            <div class="max-w-3xl mx-auto w-full">
              <.live_component
                module={section_module(@edit_section)}
                id={"agent-section-#{@edit_section}"}
                agent={@agent}
                current_user={@current_user}
              />
            </div>
          </div>
        <% else %>
          <%!-- Inspect mode --%>
          <div class="flex-1 overflow-y-auto">
            <div class="p-6 max-w-3xl mx-auto w-full">
              <header class="flex items-start gap-4 mb-6">
                <div class="w-14 h-14 rounded-xl bg-base-200 border border-base-300 flex items-center justify-center text-2xl overflow-hidden shrink-0">
                  <img
                    :if={@agent.image_url}
                    src={@agent.image_url}
                    class="w-full h-full object-cover"
                    alt={@agent.name}
                  />
                  <span :if={!@agent.image_url and @agent.icon}>{@agent.icon}</span>
                  <.icon
                    :if={!@agent.image_url and !@agent.icon}
                    name="lucide-bot"
                    class="w-7 h-7 text-base-content/40"
                  />
                </div>
                <div class="flex-1 min-w-0">
                  <h1 class="text-xl font-semibold truncate">{@agent.name}</h1>
                  <p :if={@agent.handle} class="text-sm text-base-content/60 truncate">
                    @{@agent.handle}
                  </p>
                </div>
                <div class="flex gap-2 shrink-0">
                  <.workspace_share_button resource={@agent} class="btn btn-sm btn-outline" />
                  <.link
                    navigate={~p"/chat?agent=#{@agent.handle || @agent.id}"}
                    class="btn btn-sm btn-outline"
                  >
                    <.icon name="lucide-message-circle" class="w-4 h-4" /> Chat
                  </.link>
                  <button
                    type="button"
                    phx-click="enter_edit"
                    class="btn btn-sm btn-primary"
                  >
                    <.icon name="lucide-pencil" class="w-4 h-4" /> Edit
                  </button>
                </div>
              </header>

              <div class="space-y-6">
                <.content_card
                  :if={@agent.description}
                  title="Description"
                  icon="lucide-file-text"
                >
                  <p class="text-sm leading-relaxed">{@agent.description}</p>
                </.content_card>

                <.content_card :if={@agent.instructions} title="Instructions" icon="lucide-book-open">
                  <pre class="text-xs bg-base-100 border border-base-300 rounded p-3 whitespace-pre-wrap overflow-x-auto max-h-64">{@agent.instructions}</pre>
                </.content_card>

                <.content_card title="Configuration" icon="lucide-settings">
                  <dl class="grid grid-cols-2 gap-4 text-sm">
                    <div>
                      <dt class="text-xs uppercase tracking-wide text-base-content/50">Status</dt>
                      <dd>
                        <span class={["badge badge-sm", status_badge_class(@agent)]}>
                          {status_label(@agent)}
                        </span>
                      </dd>
                    </div>
                    <div :if={@agent.chat_mode}>
                      <dt class="text-xs uppercase tracking-wide text-base-content/50">
                        Default mode
                      </dt>
                      <dd>{@agent.chat_mode}</dd>
                    </div>
                    <div :if={@agent.model}>
                      <dt class="text-xs uppercase tracking-wide text-base-content/50">Model</dt>
                      <dd class="truncate">{@agent.model.name}</dd>
                    </div>
                    <div>
                      <dt class="text-xs uppercase tracking-wide text-base-content/50">Heartbeat</dt>
                      <dd>
                        {if @agent.heartbeat_enabled,
                          do: "Every #{@agent.heartbeat_default_interval_minutes}m",
                          else: "Off"}
                      </dd>
                    </div>
                    <div :if={@agent.max_iterations}>
                      <dt class="text-xs uppercase tracking-wide text-base-content/50">
                        Max iterations
                      </dt>
                      <dd>{@agent.max_iterations}</dd>
                    </div>
                    <div :if={@agent.max_daily_runs}>
                      <dt class="text-xs uppercase tracking-wide text-base-content/50">
                        Daily run limit
                      </dt>
                      <dd>{@agent.max_daily_runs}</dd>
                    </div>
                  </dl>
                </.content_card>

                <.content_card title="Privacy & Access" icon="lucide-shield">
                  <ul class="space-y-2 text-sm">
                    <.access_row
                      label="Read global memories"
                      enabled={@agent.can_read_global_memories}
                    />
                    <.access_row
                      label="Write global memories"
                      enabled={@agent.can_write_global_memories}
                    />
                    <.access_row label="Access global files" enabled={@agent.can_access_global_files} />
                    <.access_row label="Access knowledge" enabled={@agent.can_access_knowledge} />
                  </ul>
                </.content_card>

                <.content_card title="Integrations" icon="lucide-plug">
                  <.integration_list integrations={@integrations} />
                </.content_card>

                <.content_card
                  title="Inbox"
                  icon="lucide-inbox"
                  subtitle={inbox_subtitle(@inbox_pending_count)}
                >
                  <.inbox_list inbox_events={@inbox_events} />
                </.content_card>

                <.content_card title="Activity" icon="lucide-activity">
                  <.activity_list activity_logs={@activity_logs} />
                </.content_card>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_create_form(assigns) do
    ~H"""
    <div class="flex-1 overflow-y-auto">
      <div class="p-6 max-w-2xl mx-auto w-full">
        <header class="mb-6">
          <h1 class="text-xl font-semibold">{gettext("New Agent")}</h1>
          <p class="text-sm text-wb-text-muted mt-1">
            {gettext(
              "Give your agent a name and short description. You can configure tools, instructions, and more after creating it."
            )}
          </p>
        </header>

        <.form
          for={@create_form}
          phx-submit="save_create"
          phx-change="validate_create"
          class="space-y-6"
        >
          <div class="bg-wb-surface border border-wb-border rounded-xl p-5">
            <div class="space-y-4">
              <.input
                field={@create_form[:name]}
                type="text"
                label={gettext("Name")}
                placeholder={gettext("e.g. Research Assistant")}
                required
              />

              <.input
                field={@create_form[:description]}
                type="textarea"
                label={gettext("Description")}
                placeholder={gettext("What does this agent do? When should it be used?")}
                class="textarea h-24"
              />
            </div>
          </div>

          <div class="flex items-center justify-between pt-2 pb-6">
            <button type="button" phx-click="cancel_create" class="btn btn-ghost btn-sm">
              {gettext("Cancel")}
            </button>
            <button type="submit" class="btn btn-primary btn-sm">
              {gettext("Create Agent")}
            </button>
          </div>
        </.form>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Function components
  # ---------------------------------------------------------------------------

  defp inbox_subtitle(0), do: "Nothing pending."
  defp inbox_subtitle(1), do: "1 item needs attention."
  defp inbox_subtitle(n), do: "#{n} items need attention."

  defp status_label(%{is_paused: true}), do: "Paused"
  defp status_label(%{heartbeat_enabled: true}), do: "Active"
  defp status_label(_), do: "Idle"

  defp status_badge_class(%{is_paused: true}), do: "badge-warning"
  defp status_badge_class(%{heartbeat_enabled: true}), do: "badge-success"
  defp status_badge_class(_), do: "badge-ghost"

  attr :label, :string, required: true
  attr :enabled, :boolean, required: true

  defp access_row(assigns) do
    ~H"""
    <li class="flex items-center justify-between">
      <span class="text-base-content/80">{@label}</span>
      <span class={[
        "inline-flex items-center gap-1 text-xs",
        if(@enabled, do: "text-success", else: "text-base-content/40")
      ]}>
        <.icon name={if(@enabled, do: "lucide-check", else: "lucide-x")} class="w-4 h-4" />
        {if @enabled, do: "Allowed", else: "Denied"}
      </span>
    </li>
    """
  end

  attr :integrations, :list, required: true

  defp integration_list(assigns) do
    ~H"""
    <div :if={@integrations == []} class="text-sm text-base-content/50 py-2">
      No integrations connected.
    </div>
    <ul :if={@integrations != []} class="space-y-2">
      <li
        :for={integration <- @integrations}
        class="flex items-center gap-3 p-3 rounded-lg bg-base-100 border border-base-300"
      >
        <div class="flex-1 min-w-0">
          <p class="text-sm font-medium truncate">
            {provider_label(integration.provider_key)}
          </p>
          <p :if={integration.external_id} class="text-xs text-base-content/50 truncate">
            {integration.external_id}
          </p>
        </div>
        <span class={["badge badge-xs", integration_status_class(integration.status)]}>
          {integration.status}
        </span>
      </li>
    </ul>
    """
  end

  defp provider_label(key) when is_atom(key) do
    case Magus.Integrations.get_provider_module(key) do
      nil -> Phoenix.Naming.humanize(key)
      mod -> mod.name()
    end
  end

  defp provider_label(_), do: "Unknown"

  defp integration_status_class(:active), do: "badge-success"
  defp integration_status_class(:pending), do: "badge-warning"
  defp integration_status_class(:error), do: "badge-error"
  defp integration_status_class(_), do: "badge-ghost"

  attr :inbox_events, :list, required: true

  defp inbox_list(assigns) do
    ~H"""
    <div :if={@inbox_events == []} class="text-sm text-base-content/50 py-2">
      Inbox is empty.
    </div>
    <ul :if={@inbox_events != []} class="space-y-2">
      <li
        :for={event <- @inbox_events}
        class="flex items-start gap-3 p-3 rounded-lg bg-base-100 border border-base-300"
      >
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2 flex-wrap">
            <span class={["badge badge-sm", event_type_badge_class(event.event_type)]}>
              {event_type_label(event.event_type)}
            </span>
            <span class={["badge badge-xs", event_status_badge_class(event.status)]}>
              {event_status_label(event.status)}
            </span>
            <span :if={event.urgency == :immediate} class="badge badge-xs badge-warning">
              Urgent
            </span>
            <span class="text-xs text-base-content/40 ml-auto shrink-0">
              {relative_time(event.inserted_at)}
            </span>
          </div>
          <p class="text-sm font-medium text-base-content mt-1 truncate">{event.title}</p>
          <p :if={event.summary} class="text-xs text-base-content/60 mt-0.5 line-clamp-2">
            {event.summary}
          </p>
        </div>
        <button
          :if={event.status in [:pending, :waiting, :processing]}
          phx-click="dismiss_event"
          phx-value-id={event.id}
          class="btn btn-ghost btn-xs text-base-content/40 hover:text-base-content shrink-0"
          title="Dismiss"
        >
          <.icon name="lucide-x" class="w-3 h-3" />
        </button>
      </li>
    </ul>
    """
  end

  attr :activity_logs, :list, required: true

  defp activity_list(assigns) do
    ~H"""
    <div :if={@activity_logs == []} class="text-sm text-base-content/50 py-2">
      No activity yet.
    </div>
    <ul :if={@activity_logs != []} class="space-y-1">
      <li :for={log <- @activity_logs} class="py-1.5 group">
        <div class="flex items-center gap-2">
          <div class={["w-1.5 h-1.5 rounded-full shrink-0", activity_dot_class(log.activity_type)]} />
          <span class={[
            "text-[11px] px-1.5 py-0.5 rounded shrink-0",
            activity_badge_class(log.activity_type)
          ]}>
            {activity_type_label(log.activity_type)}
          </span>
          <span class="text-sm text-base-content/80 truncate flex-1">{log.summary}</span>
          <.link
            :if={log.conversation_id}
            navigate={~p"/chat/#{log.conversation_id}"}
            class="opacity-0 group-hover:opacity-100 shrink-0 text-primary hover:underline text-xs flex items-center gap-1"
          >
            <.icon name="lucide-external-link" class="w-3 h-3" />
          </.link>
          <span class="text-xs text-base-content/40 tabular-nums shrink-0 min-w-[5rem] text-right">
            {relative_time(log.inserted_at)}
          </span>
        </div>
      </li>
    </ul>
    """
  end

  defp event_type_label(:mention), do: "Mention"
  defp event_type_label(:task_assigned), do: "Task"
  defp event_type_label(:approval_response), do: "Approval"
  defp event_type_label(:content), do: "Content"
  defp event_type_label(:heartbeat), do: "Heartbeat"
  defp event_type_label(:integration), do: "Integration"
  defp event_type_label(:agent_message), do: "Agent"
  defp event_type_label(:system), do: "System"
  defp event_type_label(_), do: "Event"

  defp event_type_badge_class(:mention), do: "badge-primary"
  defp event_type_badge_class(:task_assigned), do: "badge-info"
  defp event_type_badge_class(:approval_response), do: "badge-warning"
  defp event_type_badge_class(:heartbeat), do: "badge-ghost"
  defp event_type_badge_class(:integration), do: "badge-secondary"
  defp event_type_badge_class(_), do: "badge-ghost"

  defp event_status_label(:pending), do: "Pending"
  defp event_status_label(:processing), do: "Processing"
  defp event_status_label(:waiting), do: "Waiting"
  defp event_status_label(:resolved), do: "Resolved"
  defp event_status_label(:dismissed), do: "Dismissed"
  defp event_status_label(:expired), do: "Expired"
  defp event_status_label(_), do: "Unknown"

  defp event_status_badge_class(:pending), do: "badge-warning"
  defp event_status_badge_class(:processing), do: "badge-info"
  defp event_status_badge_class(:waiting), do: "badge-warning"
  defp event_status_badge_class(:resolved), do: "badge-success"
  defp event_status_badge_class(:dismissed), do: "badge-ghost"
  defp event_status_badge_class(:expired), do: "badge-ghost"
  defp event_status_badge_class(_), do: "badge-ghost"

  # ---------------------------------------------------------------------------
  # handle_info — ProfileImageGeneratorComponent messages from General section
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:set_edit_state, edit?, section}, socket) do
    {:noreply,
     socket
     |> assign(:edit?, edit?)
     |> assign(:edit_section, parse_section(section))}
  end

  def handle_info(%{type: "activity.new"}, socket) do
    {:noreply, load_overview_data(socket)}
  end

  def handle_info(%{type: "activity.inbox_changed"}, socket) do
    {:noreply, load_overview_data(socket)}
  end

  def handle_info(%{type: "activity.status_changed"}, socket) do
    {:noreply, socket}
  end

  def handle_info(
        {MagusWeb.ProfileImageGeneratorComponent, {:task_started, ref}},
        socket
      ) do
    {:noreply, assign(socket, :profile_gen_ref, ref)}
  end

  def handle_info({ref, result}, %{assigns: %{profile_gen_ref: ref}} = socket)
      when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    send_update(MagusWeb.ProfileImageGeneratorComponent,
      id: "agent-profile-image-gen-agent-section-general",
      task_result: result
    )

    {:noreply, assign(socket, :profile_gen_ref, nil)}
  end

  def handle_info(
        {MagusWeb.ProfileImageGeneratorComponent, {:image_generated, path}},
        socket
      ) do
    send_update(Sections.General,
      id: "agent-section-general",
      image_gen_result: path
    )

    {:noreply, socket}
  end

  def handle_info({MagusWeb.ProfileImageGeneratorComponent, :cancelled}, socket) do
    send_update(Sections.General,
      id: "agent-section-general",
      image_gen_cancelled: true
    )

    {:noreply, socket}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    {:noreply, socket}
  end

  # Integrations wizard messages
  def handle_info({:wizard_complete, integration}, socket) do
    send_update(Sections.Integrations,
      id: "agent-section-integrations",
      wizard_event: :complete,
      integration: integration
    )

    {:noreply, socket}
  end

  def handle_info(:wizard_closed, socket) do
    send_update(Sections.Integrations,
      id: "agent-section-integrations",
      wizard_event: :closed
    )

    {:noreply, socket}
  end

  # File picker messages from AgentAttachmentsComponent's child FilePickerModalComponent
  def handle_info({:files_picked, _picker_id}, socket) do
    send_update(MagusWeb.AgentsLive.Components.AgentAttachmentsComponent,
      id: "agent-attachments",
      custom_agent_id: socket.assigns.agent.id,
      current_user: socket.assigns.current_user,
      show_picker: false
    )

    {:noreply, socket}
  end

  def handle_info({:close_picker, _picker_id}, socket) do
    send_update(MagusWeb.AgentsLive.Components.AgentAttachmentsComponent,
      id: "agent-attachments",
      custom_agent_id: socket.assigns.agent.id,
      current_user: socket.assigns.current_user,
      show_picker: false
    )

    {:noreply, socket}
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  defp toggle_agent_share(socket, action) do
    user = socket.assigns.current_user
    agent = socket.assigns.agent

    result =
      case action do
        :share -> WorkspaceShare.share(:custom_agent, agent, user)
        :unshare -> WorkspaceShare.unshare(:custom_agent, agent, user)
      end

    case result do
      {:ok, _} ->
        case Magus.Agents.get_custom_agent(agent.id,
               actor: user,
               load: [:model, :image_model, :video_model, :image_url, :is_shared_to_workspace]
             ) do
          {:ok, refreshed} -> assign(socket, :agent, refreshed)
          _ -> socket
        end

      :no_workspace ->
        socket

      {:error, _} ->
        put_flash(socket, :error, agent_share_error(action))
    end
  end

  defp agent_share_error(:share), do: gettext("Couldn't share this agent.")
  defp agent_share_error(:unshare), do: gettext("Couldn't unshare this agent.")
end
