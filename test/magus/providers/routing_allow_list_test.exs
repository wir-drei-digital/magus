defmodule Magus.Providers.RoutingAllowListTest do
  use Magus.DataCase, async: true

  alias Magus.Models
  alias Magus.Providers.Routing

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
end
