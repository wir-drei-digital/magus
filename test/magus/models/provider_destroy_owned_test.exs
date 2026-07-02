defmodule Magus.Models.ProviderDestroyOwnedTest do
  use Magus.DataCase, async: false
  import Magus.Generators

  setup do
    Magus.DataCase.clear_catalog!()
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

    %{user: user, provider: provider, model: model}
  end

  test "owner destroys provider, models cascade", %{user: user, provider: provider, model: model} do
    assert :ok = Magus.Models.destroy_owned_provider(provider, actor: user)
    assert {:error, _} = Ash.get(Magus.Chat.Model, model.id, authorize?: false)
    assert {:error, _} = Ash.get(Magus.Models.Provider, provider.id, authorize?: false)
  end

  test "non-owner refused", %{provider: provider} do
    other = generate(user())
    assert {:error, _} = Magus.Models.destroy_owned_provider(provider, actor: other)
  end

  test "owner destroys a single owned model", %{user: user, model: model} do
    assert :ok = Magus.Chat.destroy_owned_model(model, actor: user)
    assert {:error, _} = Ash.get(Magus.Chat.Model, model.id, authorize?: false)
  end

  test "non-owner cannot destroy the model", %{model: model} do
    other = generate(user())
    assert {:error, _} = Magus.Chat.destroy_owned_model(model, actor: other)
  end
end
