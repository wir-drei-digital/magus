defmodule MagusWeb.Workbench.Resources.Companions.ServiceCompanion do
  @moduledoc """
  LiveView wrapper around the existing `ServicePaneComponent`. Mounted via
  `live_render` from `TabContainer` when a tab's companion is a service pane.

  Companion spec: `%{"type" => "service", "id" => conversation_id}`.

  Receives in session:
    - `"conversation_id"` — UUID of the conversation whose sandbox service to show
    - `"user_id"` — UUID of the current user
    - `"tab_id"` — workbench tab id (for broadcasting :close_companion back)

  Owns:
    - Service state loading (via `Magus.Sandbox.get_sandbox_by_conversation/2`)
    - Periodic sandbox polling to keep status accurate
    - Reload / restart logic (mirrors ChatLive.SandboxHandlers)
  """
  use MagusWeb, :live_view

  alias MagusWeb.ChatLive.Components.Service.ServicePaneComponent
  alias MagusWeb.Workbench.Signals

  # Poll sandbox state every 2 minutes while the service pane is open
  @poll_interval :timer.minutes(2)

  @impl true
  def mount(_params, session, socket) do
    conversation_id = session["conversation_id"]
    user_id = session["user_id"]
    tab_id = session["tab_id"]

    user = Magus.Accounts.get_user!(user_id, authorize?: false)

    service = load_service_state(conversation_id, user)

    if connected?(socket) do
      schedule_poll()
    end

    {:ok,
     socket
     |> assign(:current_user, user)
     |> assign(:conversation_id, conversation_id)
     |> assign(:tab_id, tab_id)
     |> assign(:service, service)
     |> assign(:capture_mode, false)
     |> assign(:reloading, service.status == "reloading")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      data-service-companion
      data-conversation-id={@conversation_id}
      class="h-full flex flex-col"
    >
      <.live_component
        module={ServicePaneComponent}
        id={"service-companion-#{@conversation_id}"}
        service={@service}
        capture_mode={@capture_mode}
        reloading={@reloading}
      />
    </div>
    """
  end

  # ============================================================================
  # Event handlers
  # ============================================================================

  @impl true
  def handle_event("close_pane", _params, socket) do
    Signals.broadcast_close_companion(socket.assigns.tab_id)
    {:noreply, socket}
  end

  def handle_event("reload_service", _params, socket) do
    conversation_id = socket.assigns.conversation_id

    socket =
      socket
      |> assign(:service, %{socket.assigns.service | status: "reloading"})
      |> assign(:reloading, true)

    send(self(), {:reload_service, conversation_id})
    {:noreply, socket}
  end

  def handle_event("toggle_service_capture", _params, socket) do
    {:noreply, assign(socket, :capture_mode, !socket.assigns.capture_mode)}
  end

  # ============================================================================
  # Info handlers
  # ============================================================================

  @impl true
  def handle_info(:sandbox_poll, socket) do
    conversation_id = socket.assigns.conversation_id
    user = socket.assigns.current_user

    status =
      case Magus.Sandbox.get_sandbox_by_conversation(conversation_id, actor: user) do
        {:ok, [%{service_port: port} = sandbox | _]} when is_integer(port) ->
          case sandbox.state do
            :active -> "running"
            :suspended -> "suspended"
            _ -> "stopped"
          end

        _ ->
          "stopped"
      end

    schedule_poll()

    {:noreply,
     socket
     |> assign(:service, %{socket.assigns.service | status: status})
     |> assign(:reloading, status == "reloading")}
  end

  def handle_info({:reload_service, conversation_id}, socket) do
    user = socket.assigns.current_user

    socket =
      case Magus.Sandbox.get_sandbox_by_conversation(conversation_id, actor: user) do
        {:ok, [%{state: :active, service_config: config} | _]} when is_map(config) ->
          restart_service(socket, conversation_id, config, user)

        {:ok, [%{state: :active} | _]} ->
          update_status(socket, "running")

        {:ok, [%{state: :suspended, service_config: config} = sandbox | _]}
        when is_map(config) ->
          case Magus.Sandbox.resume(sandbox, actor: user) do
            {:ok, _} -> restart_service(socket, conversation_id, config, user)
            _ -> update_status(socket, "error")
          end

        {:ok, [%{state: :suspended} = sandbox | _]} ->
          case Magus.Sandbox.resume(sandbox, actor: user) do
            {:ok, _} -> update_status(socket, "running")
            _ -> update_status(socket, "error")
          end

        _ ->
          update_status(socket, "error")
      end

    {:noreply, socket}
  end

  def handle_info(_unhandled, socket), do: {:noreply, socket}

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp load_service_state(conversation_id, user) do
    {status, port} =
      case Magus.Sandbox.get_sandbox_by_conversation(conversation_id, actor: user) do
        {:ok, [%{service_port: port} = sandbox | _]} when is_integer(port) ->
          status =
            case sandbox.state do
              :active -> "running"
              :suspended -> "suspended"
              _ -> "stopped"
            end

          {status, port}

        _ ->
          {"stopped", nil}
      end

    %{
      preview_url: "/sandbox/preview/#{conversation_id}/",
      name: "service",
      status: status,
      port: port
    }
  end

  defp restart_service(socket, conversation_id, config, user) do
    name = config["name"] || config[:name] || "service"

    Magus.Sandbox.Orchestrator.stop_service(conversation_id, name, user_id: user.id)

    service_config = %{
      name: name,
      command: config["command"] || config[:command],
      args: config["args"] || config[:args] || [],
      port: config["port"] || config[:port],
      working_dir: config["working_dir"] || config[:working_dir] || "/workspace"
    }

    case Magus.Sandbox.Orchestrator.start_service(conversation_id, service_config,
           user_id: user.id
         ) do
      {:ok, _} -> update_status(socket, "running")
      _ -> update_status(socket, "error")
    end
  end

  defp update_status(socket, status) do
    socket
    |> assign(:service, %{socket.assigns.service | status: status})
    |> assign(:reloading, status == "reloading")
  end

  defp schedule_poll do
    Process.send_after(self(), :sandbox_poll, @poll_interval)
  end
end
