defmodule Magus.Models.Provider.Changes.SetOwnerFromActor do
  @moduledoc "Sets owner_user_id to the acting user's id on :create_owned."
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, %{actor: %{id: id}}) when is_binary(id) do
    Ash.Changeset.force_change_attribute(changeset, :owner_user_id, id)
  end

  def change(changeset, _opts, _context) do
    Ash.Changeset.add_error(changeset, field: :owner_user_id, message: "requires an actor")
  end
end
