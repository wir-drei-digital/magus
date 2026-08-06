defmodule Magus.Providers.RoutingAllowListTest do
  use Magus.DataCase, async: true

  alias Magus.Models
  alias Magus.Providers.Routing

  # The seed migration commits US/EU/CH provider rows (allowed: true) into the
  # shared test DB. Clear them (transaction-local, rolled back) so each test
  # controls the allow-list it exercises.
  setup do
    Magus.DataCase.clear_open_router_providers!()
    :ok
  end

  defp allow(slug) do
    # upsert/set_allowed are admin-gated; the seed path bypasses like the sync module.
    {:ok, p} = Models.upsert_open_router_provider(%{slug: slug, name: slug}, authorize?: false)
    {:ok, _} = Models.set_open_router_provider_allowed(p, true, authorize?: false)
  end

  test "non-openrouter model returns nil" do
    assert Routing.build_provider_routing(%{api_provider: :xai, denied_providers: []}) == nil
  end

  test "no providers allowed at all fails open with data_collection deny" do
    model = %{api_provider: :openrouter, denied_providers: []}
    assert Routing.build_provider_routing(model) == %{"data_collection" => "deny"}
  end

  test "allowed minus model denies produces only-list" do
    allow("anthropic")
    allow("mistral")
    model = %{api_provider: :openrouter, denied_providers: ["mistral"]}

    assert %{"only" => only, "data_collection" => "deny"} =
             Routing.build_provider_routing(model)

    assert Enum.sort(only) == ["anthropic"]
  end

  test "denies removing every allowed provider is an error, never only: []" do
    allow("anthropic")
    model = %{api_provider: :openrouter, denied_providers: ["anthropic"]}
    assert Routing.build_provider_routing(model) == {:error, :no_allowed_providers}
  end

  describe "build_provider_routing_for_key/1 (background LLM calls)" do
    test "non-openrouter key returns nil" do
      assert Routing.build_provider_routing_for_key("xai:grok-test") == nil
      assert Routing.build_provider_routing_for_key("u_someslug:claude-x") == nil
    end

    test "an unregistered openrouter key gets allow-list-only routing" do
      allow("anthropic")

      assert %{"only" => ["anthropic"], "data_collection" => "deny"} =
               Routing.build_provider_routing_for_key("openrouter:vendor/not-in-catalog")
    end

    test "a catalog key applies its per-model denies" do
      allow("anthropic")
      allow("mistral")

      model =
        Ash.create!(
          Magus.Chat.Model,
          %{
            name: "Routed",
            key: "openrouter:test/routed-#{System.unique_integer([:positive])}",
            provider: "test",
            api_provider: :openrouter,
            denied_providers: ["mistral"]
          },
          action: :create,
          authorize?: false
        )

      assert %{"only" => ["anthropic"], "data_collection" => "deny"} =
               Routing.build_provider_routing_for_key(model.key)
    end

    test "a catalog key whose denies empty the list returns the error" do
      allow("anthropic")

      model =
        Ash.create!(
          Magus.Chat.Model,
          %{
            name: "Denied",
            key: "openrouter:test/denied-#{System.unique_integer([:positive])}",
            provider: "test",
            api_provider: :openrouter,
            denied_providers: ["anthropic"]
          },
          action: :create,
          authorize?: false
        )

      assert Routing.build_provider_routing_for_key(model.key) ==
               {:error, :no_allowed_providers}
    end
  end

  describe "Clients.LLM.provider_options/2 routing injection" do
    test "an openrouter key gains :openrouter_provider in opts" do
      allow("anthropic")

      {_model, opts} =
        Magus.Agents.Clients.LLM.provider_options("openrouter:vendor/bg-model", [])

      assert %{"only" => ["anthropic"], "data_collection" => "deny"} =
               opts[:openrouter_provider]
    end

    test "preflight-computed routing in opts wins over the seam" do
      allow("anthropic")
      preset = %{"only" => ["from-preflight"], "data_collection" => "deny"}

      {_model, opts} =
        Magus.Agents.Clients.LLM.provider_options("openrouter:vendor/bg-model",
          openrouter_provider: preset
        )

      assert opts[:openrouter_provider] == preset
    end

    test "non-openrouter keys are untouched" do
      {_model, opts} = Magus.Agents.Clients.LLM.provider_options("xai:grok-test", [])
      refute Keyword.has_key?(opts, :openrouter_provider)
    end

    test "a fully-denied model continues unrouted (skip-with-log)" do
      allow("anthropic")

      model =
        Ash.create!(
          Magus.Chat.Model,
          %{
            name: "BG Denied",
            key: "openrouter:test/bg-denied-#{System.unique_integer([:positive])}",
            provider: "test",
            api_provider: :openrouter,
            denied_providers: ["anthropic"]
          },
          action: :create,
          authorize?: false
        )

      {_model, opts} = Magus.Agents.Clients.LLM.provider_options(model.key, [])
      refute Keyword.has_key?(opts, :openrouter_provider)
    end
  end
end
