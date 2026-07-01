defmodule Magus.Chat.Model.Validations.SelectableByActor do
  @moduledoc """
  Validates that the selected model id (from `opts[:attribute]`) resolves, under
  the acting actor, to an active, non-internal model the actor may use. A nil id
  is allowed (clearing the selection).

  Global (unowned) models remain selectable by anyone; owned models are only
  selectable by their owner. The owner filter is branched on whether the actor
  has a binary id so an actor-less caller never compares `owner_user_id` against
  a nil pin (which would emit a runtime warning). See `Magus.Chat.Model`'s
  `list_active` for the same pattern.
  """
  use Ash.Resource.Validation
  require Ash.Query

  @impl true
  def init(opts) do
    if is_atom(opts[:attribute]),
      do: {:ok, opts},
      else: {:error, "attribute option is required"}
  end

  @impl true
  def validate(changeset, opts, context) do
    field = opts[:attribute]

    case Ash.Changeset.get_attribute(changeset, field) do
      nil ->
        :ok

      id ->
        query = selectable_query(id, actor_id(context))

        case Ash.read_one(query, authorize?: false) do
          {:ok, %{}} -> :ok
          _ -> {:error, field: field, message: "is not a selectable model"}
        end
    end
  end

  defp selectable_query(id, actor_id) when is_binary(actor_id) do
    Ash.Query.filter(
      Magus.Chat.Model,
      id == ^id and active? == true and internal? == false and
        (is_nil(owner_user_id) or owner_user_id == ^actor_id)
    )
  end

  defp selectable_query(id, _actor_id) do
    Ash.Query.filter(
      Magus.Chat.Model,
      id == ^id and active? == true and internal? == false and is_nil(owner_user_id)
    )
  end

  defp actor_id(%{actor: %{id: id}}) when is_binary(id), do: id
  defp actor_id(_), do: nil
end
