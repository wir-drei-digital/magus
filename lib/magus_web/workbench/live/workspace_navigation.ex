defmodule MagusWeb.Workbench.Live.WorkspaceNavigation do
  @moduledoc """
  Cross-workspace push_navigate helper for routes that resolve to a resource
  living in a different workspace than the user's current selection.

  Calls `Magus.Accounts.select_workspace/3` to update the user's current
  workspace, then `push_navigate/2` to the requested path. On failure,
  flashes an error and redirects to `/chat`.
  """

  use MagusWeb, :verified_routes
  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

  alias Magus.Accounts

  @spec switch_and_navigate(Phoenix.LiveView.Socket.t(), String.t(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def switch_and_navigate(socket, target_workspace_id, target_path) do
    user = socket.assigns.current_user

    case Accounts.select_workspace(user, target_workspace_id, actor: user) do
      {:ok, _} ->
        push_navigate(socket, to: target_path)

      {:error, _} ->
        socket
        |> put_flash(:error, "You don't have access to that workspace")
        |> push_navigate(to: "/chat")
    end
  end
end
