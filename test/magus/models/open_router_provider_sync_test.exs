defmodule Magus.Models.OpenRouterProviderSyncTest do
  use Magus.DataCase, async: true

  alias Magus.Models
  alias Magus.Models.OpenRouterProviderSync

  defp stub(payload) do
    Req.Test.stub(OpenRouterProviderSync, fn conn ->
      Req.Test.json(conn, payload)
    end)
  end

  test "upserts providers from the API payload" do
    stub(%{
      "data" => [
        %{
          "slug" => "anthropic",
          "name" => "Anthropic",
          "headquarters" => "US",
          "datacenters" => nil
        },
        %{
          "slug" => "mistral",
          "name" => "Mistral",
          "headquarters" => "FR",
          "datacenters" => ["FR"]
        }
      ]
    })

    assert {:ok, %{synced: 2}} = OpenRouterProviderSync.sync()

    slugs =
      Models.list_open_router_providers!(authorize?: false) |> Enum.map(& &1.slug) |> Enum.sort()

    assert slugs == ["anthropic", "mistral"]

    mistral = Models.get_open_router_provider_by_slug!("mistral", authorize?: false)
    assert mistral.datacenters == ["FR"]
    assert mistral.allowed == false
  end

  test "resync preserves the admin allowed flag" do
    stub(%{"data" => [%{"slug" => "acme", "name" => "Acme"}]})
    {:ok, _} = OpenRouterProviderSync.sync()

    acme = Models.get_open_router_provider_by_slug!("acme", authorize?: false)
    {:ok, _} = Models.set_open_router_provider_allowed(acme, true, authorize?: false)

    stub(%{"data" => [%{"slug" => "acme", "name" => "Acme v2"}]})
    {:ok, _} = OpenRouterProviderSync.sync()

    acme = Models.get_open_router_provider_by_slug!("acme", authorize?: false)
    assert acme.name == "Acme v2"
    assert acme.allowed, "sync must not reset admin allow decision"
  end

  test "returns an error tuple on transport failure" do
    Req.Test.stub(OpenRouterProviderSync, fn conn ->
      Req.Test.transport_error(conn, :econnrefused)
    end)

    assert {:error, _} = OpenRouterProviderSync.sync()
  end
end
