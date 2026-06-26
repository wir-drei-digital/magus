defmodule Magus.Workspaces.Changes.GrantWorkspaceAccess do
  @moduledoc """
  `after_action` change that idempotently creates a `:workspace` grant on
  `Magus.Workspaces.ResourceAccess` for the updated record.

  The record must have `id` and `workspace_id` fields. The grant is created with
  `grantee_type: :workspace, grantee_id: record.workspace_id`.

  Use on `share_to_team`-style update actions:

      change {Magus.Workspaces.Changes.GrantWorkspaceAccess,
              resource_type: :folder, role: :viewer}
  """

  use Ash.Resource.Change

  @impl true
  def init(opts) do
    {:ok, Keyword.put_new(opts, :role, :viewer)}
  end

  @impl true
  def change(changeset, opts, _context) do
    resource_type = Keyword.fetch!(opts, :resource_type)
    role = Keyword.fetch!(opts, :role)

    Ash.Changeset.after_action(changeset, fn _cs, record ->
      do_grant(record, resource_type, role)
    end)
  end

  defp do_grant(record, resource_type, role) do
    require Ash.Query

    existing =
      Magus.Workspaces.ResourceAccess
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        resource_type == ^resource_type and
          resource_id == ^record.id and
          grantee_type == :workspace and
          grantee_id == ^record.workspace_id
      )
      |> Ash.read!(authorize?: false)

    if existing == [] do
      case Magus.Workspaces.ResourceAccess
           |> Ash.Changeset.for_create(:grant, %{
             resource_type: resource_type,
             resource_id: record.id,
             grantee_type: :workspace,
             grantee_id: record.workspace_id,
             role: role
           })
           |> Ash.create(authorize?: false) do
        {:ok, _} ->
          {:ok, record}

        {:error, %Ash.Error.Invalid{}} ->
          # Concurrent create (unique-identity violation): treat as idempotent.
          {:ok, record}

        {:error, err} ->
          require Logger

          Logger.warning(
            "GrantWorkspaceAccess (#{resource_type}) grant create failed: #{inspect(err)}"
          )

          {:ok, record}
      end
    else
      {:ok, record}
    end
  end
end
