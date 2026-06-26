defmodule MagusWeb.ChatLive.SandboxHandlers do
  @moduledoc """
  Handles sandbox service pane events in ChatLive.

  Covers:
  - Opening/closing the service pane
  - Restoring service pane on conversation load
  - Reloading suspended sandboxes
  - Periodic sandbox state polling to keep status accurate
  """

  import Phoenix.Component, only: [assign: 3]

  # Poll sandbox state every 2 minutes while the service pane is open
  @poll_interval :timer.minutes(2)

  @doc """
  Opens the service pane for the current conversation.
  Persists the pane state so it survives page reloads.
  """
  def handle_open_service_pane(socket, opts \\ []) do
    conversation_id = socket.assigns.conversation.id
    user = socket.assigns.current_user

    service_data = build_service_data(conversation_id, opts)

    Magus.Chat.set_pane(
      conversation_id,
      user.id,
      :service,
      conversation_id,
      actor: user
    )

    socket
    |> assign(:pane, :service)
    |> assign(:active_service, service_data)
    |> assign(:show_mobile_pane, false)
    |> schedule_sandbox_poll()
  end

  @doc """
  Sets the service pane status to "reloading" and sends a message
  to trigger the async sandbox wake-up.
  """
  def handle_reload_service(socket) do
    conversation_id = socket.assigns.conversation.id

    socket =
      if service = socket.assigns[:active_service] do
        assign(socket, :active_service, %{service | status: "reloading"})
      else
        socket
      end

    send(self(), {:reload_service, conversation_id})
    socket
  end

  @doc """
  Async handler for waking a suspended sandbox.
  Called via `handle_info({:reload_service, conversation_id}, socket)`.
  """
  def handle_reload_service_async(socket, conversation_id) do
    user = socket.assigns.current_user

    case Magus.Sandbox.get_sandbox_by_conversation(conversation_id, actor: user) do
      {:ok, [%{state: :active, service_config: config} | _]} when is_map(config) ->
        # Active sandbox with saved config: restart the service process
        restart_service(socket, conversation_id, config, user)

      {:ok, [%{state: :active} | _]} ->
        # Active but no saved config, nothing to restart
        update_service_status(socket, "running")

      {:ok, [%{state: :suspended, service_config: config} = sandbox | _]} when is_map(config) ->
        # Suspended with config: resume then restart service
        case Magus.Sandbox.resume(sandbox, actor: user) do
          {:ok, _} -> restart_service(socket, conversation_id, config, user)
          _ -> update_service_status(socket, "error")
        end

      {:ok, [%{state: :suspended} = sandbox | _]} ->
        # Suspended without config: just resume
        case Magus.Sandbox.resume(sandbox, actor: user) do
          {:ok, _} -> update_service_status(socket, "running")
          _ -> update_service_status(socket, "error")
        end

      _ ->
        update_service_status(socket, "error")
    end
  end

  defp restart_service(socket, conversation_id, config, user) do
    name = config["name"] || config[:name] || "service"

    # Stop the existing service first (ignore errors -- it may not be running)
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
      {:ok, _} ->
        update_service_status(socket, "running")

      _ ->
        update_service_status(socket, "error")
    end
  end

  @doc """
  Checks the sandbox state and updates the service pane status.
  Called periodically via `handle_info(:sandbox_poll, socket)`.
  """
  def handle_sandbox_poll(socket) do
    if socket.assigns[:pane] == :service && socket.assigns[:active_service] do
      conversation_id = socket.assigns.conversation.id
      user = socket.assigns.current_user

      socket =
        case Magus.Sandbox.get_sandbox_by_conversation(conversation_id, actor: user) do
          {:ok, [%{service_port: port} = sandbox | _]} when is_integer(port) ->
            status =
              case sandbox.state do
                :active -> "running"
                :suspended -> "suspended"
                _ -> "stopped"
              end

            update_service_status(socket, status)

          _ ->
            update_service_status(socket, "stopped")
        end

      schedule_sandbox_poll(socket)
    else
      socket
    end
  end

  @doc """
  Restores the service pane when navigating back to a conversation.
  Checks if the sandbox is still alive and shows appropriate status.
  """
  def maybe_restore_service_pane(socket, conversation_id) do
    user = socket.assigns.current_user

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

    service_data = build_service_data(conversation_id, status: status, port: port)

    socket
    |> assign(:pane, :service)
    |> assign(:active_service, service_data)
    |> schedule_sandbox_poll()
  end

  defp build_service_data(conversation_id, opts) do
    %{
      preview_url: "/sandbox/preview/#{conversation_id}/",
      name: opts[:name] || "service",
      status: opts[:status] || "running",
      port: opts[:port]
    }
  end

  defp update_service_status(socket, status) do
    if service = socket.assigns[:active_service] do
      assign(socket, :active_service, %{service | status: status})
    else
      socket
    end
  end

  defp schedule_sandbox_poll(socket) do
    Process.send_after(self(), :sandbox_poll, @poll_interval)
    socket
  end
end
