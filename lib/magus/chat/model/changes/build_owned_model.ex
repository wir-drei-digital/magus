defmodule Magus.Chat.Model.Changes.BuildOwnedModel do
  @moduledoc """
  Wires a user-owned model to its owned provider: verifies the actor owns the
  provider, mirrors owner_user_id, forces api_provider :byok, mints the
  slug-prefixed key from the `model_id` argument, and blocks media models
  (image/video are Phase 5, since the media clients bypass RequestOptions).
  """
  use Ash.Resource.Change
  require Ash.Query

  @impl true
  def change(changeset, _opts, %{actor: %{id: actor_id}}) when is_binary(actor_id) do
    Ash.Changeset.before_action(changeset, fn cs ->
      provider_id = Ash.Changeset.get_attribute(cs, :model_provider_id)
      model_id = Ash.Changeset.get_argument(cs, :model_id)
      out = Ash.Changeset.get_attribute(cs, :output_modalities) || ["text"]

      cond do
        is_nil(provider_id) ->
          Ash.Changeset.add_error(cs, field: :model_provider_id, message: "is required")

        Enum.any?(out, &(&1 in ["image", "video"])) ->
          Ash.Changeset.add_error(cs,
            field: :output_modalities,
            message: "media models are not supported yet"
          )

        true ->
          case owned_provider(provider_id, actor_id) do
            {:ok, provider} ->
              cs
              |> Ash.Changeset.force_change_attribute(:owner_user_id, actor_id)
              |> Ash.Changeset.force_change_attribute(:api_provider, :byok)
              |> Ash.Changeset.force_change_attribute(:key, "#{provider.slug}:#{model_id}")

            :error ->
              Ash.Changeset.add_error(cs,
                field: :model_provider_id,
                message: "must be a provider you own"
              )
          end
      end
    end)
  end

  def change(changeset, _opts, _context),
    do: Ash.Changeset.add_error(changeset, field: :owner_user_id, message: "requires an actor")

  defp owned_provider(provider_id, actor_id) do
    case Magus.Models.Provider
         |> Ash.Query.filter(id == ^provider_id and owner_user_id == ^actor_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %{} = provider} -> {:ok, provider}
      _ -> :error
    end
  end
end
