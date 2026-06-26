defmodule Magus.Workspaces.WorkspaceMember.Checks.ActorIsWorkspaceAdmin do
  @moduledoc """
  Custom policy check that verifies the actor is an active admin of the workspace.

  Works with create actions (where expr-based policies cannot reference relationships).
  Reads workspace_id from the changeset argument.
  """

  use Ash.Policy.SimpleCheck

  require Ash.Query

  @impl true
  def describe(_opts) do
    "actor is an active admin of the workspace"
  end

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, _opts) do
    workspace_id =
      Ash.Changeset.get_argument(changeset, :workspace_id) ||
        Ash.Changeset.get_attribute(changeset, :workspace_id)

    if workspace_id do
      is_active_admin?(workspace_id, actor.id)
    else
      false
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp is_active_admin?(workspace_id, user_id) do
    Magus.Workspaces.WorkspaceMember
    |> Ash.Query.filter(
      workspace_id == ^workspace_id and
        user_id == ^user_id and
        role == :admin and
        is_active == true
    )
    |> Ash.count!(authorize?: false) > 0
  end
end
