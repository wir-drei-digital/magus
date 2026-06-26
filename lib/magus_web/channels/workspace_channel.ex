defmodule MagusWeb.WorkspaceChannel do
  @moduledoc """
  Per-workspace channel (`workspace:<workspace_id>`) for the SvelteKit
  workbench (migration iteration 5).

  Join authorizes through the same Ash policies as every other caller
  (`Magus.Workspaces.get_workspace/2` with the socket's user as actor —
  active members can read their workspace), then bridges the workspace's
  file topic:

    * `workspaces:<id>:files` (emitted by
      `Magus.Files.File.Changes.BroadcastWorkspaceEvent`) → pushed as
      `file.<event>` (`file.create` / `file.update` / `file.destroy`).
      The payload is already a JSON-safe summary (`id`, `workspace_id`,
      `action`) and is forwarded unchanged (frozen broadcast shapes).
  """
  use MagusWeb, :channel

  @impl true
  def join("workspace:" <> workspace_id, _payload, socket) do
    case Magus.Workspaces.get_workspace(workspace_id, actor: socket.assigns.current_user) do
      {:ok, workspace} ->
        Magus.Endpoint.subscribe("workspaces:#{workspace.id}:files")
        {:ok, assign(socket, :workspace_id, workspace.id)}

      {:error, _error} ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(
        %Phoenix.Socket.Broadcast{topic: "workspaces:" <> _, event: event, payload: payload},
        socket
      ) do
    push(socket, "file." <> event, payload)
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}
end
