defmodule Magus.Models.OpenRouterProviderTest do
  use Magus.DataCase, async: true

  alias Magus.Models

  # These interfaces are gated by `Magus.Checks.IsAdmin` and the Models domain
  # authorizes by default, so actor-less calls would be forbidden. The real
  # callers are the sync path (`authorize?: false`) and the admin UI (passes an
  # actor). These tests exercise the allow-preserving upsert behavior, not the
  # policy, so they call with `authorize?: false` to mirror the sync path.
  describe "upsert" do
    test "creates a row with allowed defaulting to false" do
      {:ok, p} =
        Models.upsert_open_router_provider(
          %{
            slug: "acme",
            name: "Acme",
            headquarters: "US",
            datacenters: ["US"],
            last_synced_at: ~U[2026-07-04 00:00:00Z]
          },
          authorize?: false
        )

      assert p.slug == "acme"
      assert p.allowed == false
    end

    test "resync preserves an existing row's allowed flag" do
      {:ok, p} =
        Models.upsert_open_router_provider(%{slug: "acme", name: "Acme"}, authorize?: false)

      {:ok, p} = Models.set_open_router_provider_allowed(p, true, authorize?: false)
      assert p.allowed

      {:ok, again} =
        Models.upsert_open_router_provider(%{slug: "acme", name: "Acme Renamed"},
          authorize?: false
        )

      assert again.name == "Acme Renamed"
      assert again.allowed, "resync must not reset allowed"
    end
  end

  describe "allowed read" do
    test "returns only allowed rows" do
      {:ok, a} = Models.upsert_open_router_provider(%{slug: "a", name: "A"}, authorize?: false)
      {:ok, _} = Models.set_open_router_provider_allowed(a, true, authorize?: false)
      {:ok, _b} = Models.upsert_open_router_provider(%{slug: "b", name: "B"}, authorize?: false)

      slugs =
        Models.list_allowed_open_router_providers!(authorize?: false) |> Enum.map(& &1.slug)

      assert slugs == ["a"]
    end
  end
end
