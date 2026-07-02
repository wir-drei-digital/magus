defmodule Magus.Models.RequestOptionsOwnedTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Models.RequestOptions

  setup do
    # Clear the seeded catalog so the owned provider/model created here are the
    # only rows the resolver can find. Rolled back after the test.
    Magus.DataCase.clear_catalog!()

    user = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk-owner"},
        actor: user
      )

    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{name: "C", model_id: "claude-3-5-sonnet", model_provider_id: provider.id},
        actor: user
      )

    %{user: user, provider: provider, model: model}
  end

  test "owner gets rewritten spec + key", %{user: user, provider: provider, model: model} do
    assert {"anthropic:claude-3-5-sonnet", opts} = RequestOptions.resolve(model.key, user.id)
    assert opts[:api_key] == "sk-owner"
    _ = provider
  end

  test "non-owner gets safe fallback, no key", %{model: model} do
    other = generate(user())
    assert {model_key, []} = RequestOptions.resolve(model.key, other.id)
    assert model_key == model.key
  end

  test "nil actor (default arity) gets safe fallback, no key", %{model: model} do
    assert {model_key, []} = RequestOptions.resolve(model.key)
    assert model_key == model.key
  end
end
