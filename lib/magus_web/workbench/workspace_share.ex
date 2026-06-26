defmodule MagusWeb.Workbench.WorkspaceShare do
  @moduledoc """
  Helpers for the "Share with workspace" toggle that appears in workbench
  resource view headers (chats, prompts, agents, brains, ...).

  Wraps `Magus.Workspaces.grant_access/2` and `revoke_access/2` against the
  unified `Magus.Workspaces.ResourceAccess` table so each LiveView only has
  to know its `resource_type` atom and the resource record. The resource
  must expose `id` and `workspace_id`; the latter being `nil` means the
  resource is personal and can't be shared, in which case we return
  `:no_workspace` and the caller should hide the button.
  """

  alias Magus.Workspaces

  @type resource_type :: :conversation | :prompt | :custom_agent | :brain | :file
  @type result :: {:ok, term} | :no_workspace | {:error, term}

  @spec share(resource_type, %{id: any, workspace_id: any}, Ash.Resource.record() | term) ::
          result
  def share(_resource_type, %{workspace_id: nil}, _actor), do: :no_workspace

  def share(resource_type, %{id: id, workspace_id: ws_id}, actor) do
    Workspaces.grant_access(
      %{
        resource_type: resource_type,
        resource_id: id,
        grantee_type: :workspace,
        grantee_id: ws_id,
        role: :viewer
      },
      actor: actor
    )
  end

  @spec unshare(resource_type, %{id: any, workspace_id: any}, term) :: result
  def unshare(_resource_type, %{workspace_id: nil}, _actor), do: :no_workspace

  def unshare(resource_type, %{id: id, workspace_id: ws_id}, actor) do
    with {:ok, grants} <- Workspaces.list_access_for_resource(resource_type, id, actor: actor),
         %{} = grant <-
           Enum.find(grants, fn g ->
             g.grantee_type == :workspace and g.grantee_id == ws_id
           end) do
      case Workspaces.revoke_access(grant, actor: actor) do
        :ok -> {:ok, :revoked}
        {:ok, _} -> {:ok, :revoked}
        {:error, e} -> {:error, e}
      end
    else
      # No matching workspace grant: the calc was already false or the
      # grant was concurrently revoked. Treat as a no-op success so the
      # caller refreshes UI state instead of flashing an error.
      nil -> {:ok, :already_revoked}
      {:error, e} -> {:error, e}
    end
  end
end
