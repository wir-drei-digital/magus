defmodule Magus.Models.OpenRouterProviderSeedTest do
  # async: false and NO clear_open_router_providers! setup: this test asserts on
  # the rows the seed migration committed into the shared test DB. Reads are
  # IsAdmin-gated, so every call passes authorize?: false.
  use Magus.DataCase, async: false

  alias Magus.Models

  test "seed migration marked a US provider (anthropic) allowed" do
    anthropic = Models.get_open_router_provider_by_slug!("anthropic", authorize?: false)
    assert anthropic.allowed
  end

  test "seed migration marked an EU provider (mistral) allowed" do
    mistral = Models.get_open_router_provider_by_slug!("mistral", authorize?: false)
    assert mistral.allowed
  end

  test "a CN provider (deepseek) was not seeded" do
    assert {:error, _} = Models.get_open_router_provider_by_slug("deepseek", authorize?: false)
  end
end
