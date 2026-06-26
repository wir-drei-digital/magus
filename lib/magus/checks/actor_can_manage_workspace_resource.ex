defmodule Magus.Checks.ActorCanManageWorkspaceResource do
  @moduledoc """
  Verifies that the actor can manage a mixed personal/workspace record.

  Personal records are managed by their creator. Workspace records are
  managed by their creator or an active workspace admin.

  Only applicable to update/destroy actions where the existing record is
  present on the changeset.
  """

  use Ash.Policy.SimpleCheck

  alias Magus.Checks.Helpers

  @impl true
  def describe(_opts) do
    "actor manages the resource directly or through workspace ownership"
  end

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{data: %_{} = record}}, opts) do
    match_record(actor, record, opts)
  end

  def match?(actor, %{subject: %Ash.Changeset{data: %_{} = record}}, opts) do
    match_record(actor, record, opts)
  end

  def match?(actor, %_{} = record, opts), do: match_record(actor, record, opts)
  def match?(_actor, _context, _opts), do: false

  defp match_record(actor, record, opts) do
    workspace_field = Keyword.get(opts, :workspace_field, :workspace_id)
    user_field = Keyword.get(opts, :user_field, :user_id)

    user_id = Map.get(record, user_field)
    workspace_id = Map.get(record, workspace_field)

    user_id == actor.id ||
      Helpers.active_workspace_member?(workspace_id, actor.id, admin_only?: true)
  end
end
