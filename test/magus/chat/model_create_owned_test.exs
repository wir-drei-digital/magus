defmodule Magus.Chat.ModelCreateOwnedTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  setup do
    Magus.DataCase.clear_catalog!()
    user = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk"},
        actor: user
      )

    %{user: user, provider: provider}
  end

  test "mints an owner-scoped, slug-prefixed :byok model", %{user: user, provider: provider} do
    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{
          name: "My Claude",
          model_id: "claude-3-5-sonnet",
          model_provider_id: provider.id,
          context_window: 200_000
        },
        actor: user
      )

    assert model.owner_user_id == user.id
    assert model.api_provider == :byok
    assert model.key == "#{provider.slug}:claude-3-5-sonnet"
  end

  test "rejects a provider the actor does not own", %{provider: provider} do
    other = generate(user())

    assert {:error, _} =
             Magus.Chat.create_owned_model(
               %{name: "x", model_id: "m", model_provider_id: provider.id},
               actor: other
             )
  end

  test "rejects media models", %{user: user, provider: provider} do
    assert {:error, _} =
             Magus.Chat.create_owned_model(
               %{
                 name: "img",
                 model_id: "some-image",
                 model_provider_id: provider.id,
                 output_modalities: ["image"]
               },
               actor: user
             )
  end

  test "enforces the model cap", %{user: user, provider: provider} do
    for n <- 1..50 do
      {:ok, _} =
        Magus.Chat.create_owned_model(
          %{name: "M#{n}", model_id: "m#{n}", model_provider_id: provider.id},
          actor: user
        )
    end

    assert {:error, _} =
             Magus.Chat.create_owned_model(
               %{name: "M51", model_id: "m51", model_provider_id: provider.id},
               actor: user
             )
  end
end
