defmodule Magus.Agents.Plugins.Support.PreflightRoutingTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Plugins.Support.Preflight

  test "merges a provider map under :openrouter_provider" do
    assert Preflight.apply_provider_routing(%{}, %{
             "only" => ["anthropic"],
             "data_collection" => "deny"
           }) ==
             %{openrouter_provider: %{"only" => ["anthropic"], "data_collection" => "deny"}}
  end

  test "nil routing leaves llm_opts untouched" do
    assert Preflight.apply_provider_routing(%{foo: 1}, nil) == %{foo: 1}
  end
end
