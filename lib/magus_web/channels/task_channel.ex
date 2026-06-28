defmodule MagusWeb.TaskChannel do
  @moduledoc """
  Per-plan and per-brain task channel for the SvelteKit workbench: the live
  coordination payoff (Plan 3, B6 + C3). Surfaces other clients' (agents')
  task claims / status changes / creates on the plan board and brain overview
  in real time.

  Two channel topics, each authorized through the brain read policies:

    * `plan_tasks:<brain_page_id>`: one plan board. Authorized by reading the
      brain page (`Magus.Brain.get_page`, which carries the page's brain access);
      subscribes internally to the PubSub topic `tasks:plan:<brain_page_id>`.
    * `brain_tasks:<brain_id>`: a whole brain's tasks. Authorized by reading
      the brain (`Magus.Brain.get_brain`); subscribes internally to
      `tasks:brain:<brain_id>`.

  Like `MagusWeb.BrainChannel`, the channel topic deliberately differs from the
  PubSub topic. The task PubSub payload is a raw Ash `%{task: task}` struct: if
  the channel topic matched the PubSub topic, Phoenix would route the broadcast
  through the transport fastlane (`handle_out/3`) and crash the JSON serializer.
  Subscribing internally instead lets us re-push a JSON-safe hint
  (`%{"task_id" => id}`); the client refetches its task list on any `task.*`
  event, which sidesteps stale-merge bugs.
  """
  use MagusWeb, :channel

  @impl true
  def join("plan_tasks:" <> brain_page_id, _payload, socket) do
    case Magus.Brain.get_page(brain_page_id, actor: socket.assigns.current_user) do
      {:ok, page} ->
        Magus.Endpoint.subscribe("tasks:plan:#{page.id}")
        {:ok, socket}

      {:error, _error} ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  def join("brain_tasks:" <> brain_id, _payload, socket) do
    case Magus.Brain.get_brain(brain_id, actor: socket.assigns.current_user) do
      {:ok, brain} ->
        Magus.Endpoint.subscribe("tasks:brain:#{brain.id}")
        {:ok, socket}

      {:error, _error} ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{
          topic: "tasks:" <> _,
          event: "task." <> _ = event,
          payload: payload
        },
        socket
      ) do
    push(socket, event, serialize(payload))
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp serialize(%{task: %{id: id}}), do: %{"task_id" => id}
  defp serialize(_payload), do: %{}
end
