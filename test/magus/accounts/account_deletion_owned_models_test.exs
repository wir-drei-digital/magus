defmodule Magus.Accounts.AccountDeletionOwnedModelsTest do
  use Magus.ResourceCase, async: false

  import Magus.Generators

  alias Magus.Accounts.AccountDeletion

  describe "execute/1 - owned models and providers" do
    test "deleting a user removes their owned providers and models without FK errors" do
      user = generate(user())

      {:ok, provider} =
        Magus.Models.create_owned_provider(
          %{name: "Mine", req_llm_id: "openai", api_key: "sk"},
          actor: user
        )

      {:ok, model} =
        Magus.Chat.create_owned_model(
          %{name: "M", model_id: "gpt-x", model_provider_id: provider.id},
          actor: user
        )

      # A usage row referencing the owned model. message_usages.model_id is a
      # NO ACTION FK, so without nilling it first the model delete would be
      # restricted by Postgres.
      {:ok, _usage} =
        Magus.Usage.MessageUsage
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: user.id,
            model_id: model.id,
            prompt_tokens: 10,
            completion_tokens: 5,
            model_name: "owned-model-usage"
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      assert :ok = AccountDeletion.execute(user)

      assert {:error, _} = Ash.get(Magus.Chat.Model, model.id, authorize?: false)
      assert {:error, _} = Ash.get(Magus.Models.Provider, provider.id, authorize?: false)
    end
  end
end
