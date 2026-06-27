defmodule Magus.Chat.UserModelPreference.Validations.ModelSelectable do
  @moduledoc """
  Validates that `model_id` refers to a model the user may curate. In Phase 1
  that means an active, non-internal catalog model. Owned and shared models are
  added in later phases.
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :model_id) do
      nil ->
        {:error, field: :model_id, message: "is required"}

      model_id ->
        case Magus.Chat.get_model(model_id) do
          {:ok, %{active?: true, internal?: false}} -> :ok
          _ -> {:error, field: :model_id, message: "is not a selectable model"}
        end
    end
  end
end
