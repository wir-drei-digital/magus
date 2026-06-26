defmodule Magus.Capabilities.SearchTest do
  @moduledoc """
  Tests for `Magus.Capabilities.Search`, the web-search capability dispatcher.

  The dispatcher resolves the provider from `:magus, :search_provider`
  (default: the Exa adapter) and gates off when no provider is configured.
  """
  # async: false — mutates the global :magus, :search_provider app env.
  use ExUnit.Case, async: false

  alias Magus.Capabilities.Search

  defmodule FakeProvider do
    @behaviour Magus.Capabilities.Search.Provider
    @impl true
    def configured?, do: true
    @impl true
    def search(query, opts), do: {:ok, [%{query: query, opts: opts}]}
  end

  defmodule UnconfiguredProvider do
    @behaviour Magus.Capabilities.Search.Provider
    @impl true
    def configured?, do: false
    @impl true
    def search(_query, _opts), do: {:ok, [:should_not_be_called]}
  end

  setup do
    original = Application.get_env(:magus, :search_provider)

    on_exit(fn ->
      if original do
        Application.put_env(:magus, :search_provider, original)
      else
        Application.delete_env(:magus, :search_provider)
      end
    end)
  end

  test "provider/0 defaults to the Exa adapter" do
    Application.delete_env(:magus, :search_provider)
    assert Search.provider() == Magus.Capabilities.Search.Exa
  end

  test "configured?/0 reflects the configured provider" do
    Application.put_env(:magus, :search_provider, FakeProvider)
    assert Search.configured?()

    Application.put_env(:magus, :search_provider, UnconfiguredProvider)
    refute Search.configured?()
  end

  test "search/2 delegates to the configured provider when configured" do
    Application.put_env(:magus, :search_provider, FakeProvider)
    assert {:ok, [result]} = Search.search("hello", num_results: 3)
    assert result.query == "hello"
    assert result.opts == [num_results: 3]
  end

  test "search/2 returns {:error, :not_configured} when the provider is not configured" do
    Application.put_env(:magus, :search_provider, UnconfiguredProvider)
    assert {:error, :not_configured} = Search.search("hello")
  end
end
