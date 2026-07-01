defmodule Magus.Models.Validations.WithinProviderCap do
  @moduledoc "Rejects owned-provider creation past the per-user cap."
  use Ash.Resource.Validation
  require Ash.Query

  @impl true
  def validate(_changeset, _opts, %{actor: %{id: id}}) when is_binary(id) do
    max = Keyword.fetch!(Application.fetch_env!(:magus, :user_model_limits), :max_providers)

    count =
      Magus.Models.Provider
      |> Ash.Query.filter(owner_user_id == ^id)
      |> Ash.count!(authorize?: false)

    if count >= max,
      do: {:error, field: :base, message: "provider limit reached"},
      else: :ok
  end

  def validate(_changeset, _opts, _context),
    do: {:error, field: :base, message: "requires an actor"}
end
