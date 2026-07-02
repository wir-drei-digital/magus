defmodule Magus.Models.ProviderOwnedTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  setup do
    Magus.DataCase.clear_catalog!()
    user = generate(user())
    %{user: user}
  end

  test "create_owned sets owner, mints a slug, defaults status pending", %{user: user} do
    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "My OpenAI", req_llm_id: "openai", api_key: "sk-mine"},
        actor: user
      )

    assert provider.owner_user_id == user.id
    assert provider.slug =~ ~r/\A[a-z0-9_]+\z/
    assert String.starts_with?(provider.slug, "u_")
    assert provider.validation_status == :pending
  end

  test "create_owned rejects a req_llm_id outside the allowlist", %{user: user} do
    assert {:error, _} =
             Magus.Models.create_owned_provider(
               %{name: "Nope", req_llm_id: "totally_custom", api_key: "x"},
               actor: user
             )
  end

  test "create_owned rejects an unsafe base_url", %{user: user} do
    assert {:error, _} =
             Magus.Models.create_owned_provider(
               %{
                 name: "Local",
                 req_llm_id: "openai_compatible",
                 base_url: "http://localhost:8000/v1",
                 api_key: "x"
               },
               actor: user
             )
  end

  test "create_owned enforces the provider cap", %{user: user} do
    for n <- 1..10 do
      {:ok, _} =
        Magus.Models.create_owned_provider(
          %{name: "P#{n}", req_llm_id: "openai", api_key: "k"},
          actor: user
        )
    end

    assert {:error, _} =
             Magus.Models.create_owned_provider(
               %{name: "P11", req_llm_id: "openai", api_key: "k"},
               actor: user
             )
  end

  test "a user cannot read another user's owned provider", %{user: user} do
    other = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "openai", api_key: "k"},
        actor: user
      )

    assert {:error, _} = Ash.get(Magus.Models.Provider, provider.id, actor: other)
    assert {:ok, _} = Ash.get(Magus.Models.Provider, provider.id, actor: user)
  end
end
