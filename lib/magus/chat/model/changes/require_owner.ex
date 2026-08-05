defmodule Magus.Chat.Model.Changes.RequireOwner do
  @moduledoc """
  Enforces owner-only destroy for user-owned models. Model's policies only
  cover the write floor (2b-2b: reads open, writes admin- or owner-gated), so
  this guards `:destroy_owned` by comparing the actor id to `owner_user_id`.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    actor_id =
      case context.actor do
        %{id: id} when is_binary(id) -> id
        _ -> nil
      end

    if is_binary(actor_id) and changeset.data.owner_user_id == actor_id do
      changeset
    else
      Ash.Changeset.add_error(changeset, field: :base, message: "must be a model you own")
    end
  end
end
