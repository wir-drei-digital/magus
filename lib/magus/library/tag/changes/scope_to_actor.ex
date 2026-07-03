defmodule Magus.Library.Tag.Changes.ScopeToActor do
  @moduledoc """
  Assigns tag ownership: workspace tags (workspace_id set) belong to the
  workspace alone; otherwise the tag becomes personal to the acting user.
  Without an actor (seeds, console) the tag stays legacy/global.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: actor}) do
    workspace_id = Ash.Changeset.get_attribute(changeset, :workspace_id)

    cond do
      not is_nil(workspace_id) -> changeset
      is_nil(actor) -> changeset
      true -> Ash.Changeset.force_change_attribute(changeset, :user_id, actor.id)
    end
  end
end
