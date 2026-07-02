defmodule Magus.Models.ResolverOwnershipTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Models.Resolver

  setup do
    Magus.DataCase.clear_catalog!()
    user = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk"},
        actor: user
      )

    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{name: "C", model_id: "claude-x", model_provider_id: provider.id},
        actor: user
      )

    %{user: user, model: model}
  end

  test "owner resolving their model key gets ownership facts", %{user: user, model: model} do
    {:ok, res} = Resolver.resolve(user, %{model_keys: %{chat: model.key}, mode: :chat})
    assert res.access_source == :owned
    assert res.credential_owner_user_id == user.id
    assert res.cost_source == :byok
    assert res.model.key == model.key
  end

  test "a non-owner cannot resolve the owned key (degrades)", %{model: model} do
    other = generate(user())
    {:ok, res} = Resolver.resolve(other, %{model_keys: %{chat: model.key}, mode: :chat})
    refute res.model.key == model.key
    assert res.access_source == :global
  end

  test "nil actor resolves global only", %{model: model} do
    {:ok, res} = Resolver.resolve(nil, %{model_keys: %{chat: model.key}, mode: :chat})
    refute res.model.key == model.key
  end
end
