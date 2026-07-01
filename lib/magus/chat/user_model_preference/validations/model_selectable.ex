defmodule Magus.Chat.UserModelPreference.Validations.ModelSelectable do
  @moduledoc """
  Validates that `model_id` refers to a model the user may curate: an active,
  non-internal model that is either global or owned by the acting actor. The
  owner filter is branched on whether the actor has a binary id so an actor-less
  caller never compares `owner_user_id` against a nil pin (which would emit a
  runtime warning). See `Magus.Chat.Model`'s `list_active` for the same pattern.
  """
  use Ash.Resource.Validation
  require Ash.Query

  @impl true
  def validate(changeset, _opts, context) do
    case Ash.Changeset.get_attribute(changeset, :model_id) do
      nil ->
        {:error, field: :model_id, message: "is required"}

      model_id ->
        query = selectable_query(model_id, actor_id(context))

        case Ash.read_one(query, authorize?: false) do
          {:ok, %{}} -> :ok
          _ -> {:error, field: :model_id, message: "is not a selectable model"}
        end
    end
  end

  defp selectable_query(model_id, actor_id) when is_binary(actor_id) do
    Ash.Query.filter(
      Magus.Chat.Model,
      id == ^model_id and active? == true and internal? == false and
        (is_nil(owner_user_id) or owner_user_id == ^actor_id)
    )
  end

  defp selectable_query(model_id, _actor_id) do
    Ash.Query.filter(
      Magus.Chat.Model,
      id == ^model_id and active? == true and internal? == false and is_nil(owner_user_id)
    )
  end

  defp actor_id(%{actor: %{id: id}}) when is_binary(id), do: id
  defp actor_id(_), do: nil
end
