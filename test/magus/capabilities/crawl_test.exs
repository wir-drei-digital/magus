defmodule Magus.Capabilities.CrawlTest do
  @moduledoc """
  Tests for `Magus.Capabilities.Crawl`, the web-crawl/fetch capability dispatcher.

  Resolves the provider from `:magus, :crawl_provider` (default: the Spider
  adapter) and gates off when none is configured.
  """
  # async: false — mutates the global :magus, :crawl_provider app env.
  use ExUnit.Case, async: false

  alias Magus.Capabilities.Crawl

  defmodule FakeProvider do
    @behaviour Magus.Capabilities.Crawl.Provider
    @impl true
    def configured?, do: true
    @impl true
    def fetch(urls, opts), do: {:ok, [%{urls: urls, opts: opts}]}
  end

  defmodule UnconfiguredProvider do
    @behaviour Magus.Capabilities.Crawl.Provider
    @impl true
    def configured?, do: false
    @impl true
    def fetch(_urls, _opts), do: {:ok, [:should_not_be_called]}
  end

  setup do
    original = Application.get_env(:magus, :crawl_provider)

    on_exit(fn ->
      if original do
        Application.put_env(:magus, :crawl_provider, original)
      else
        Application.delete_env(:magus, :crawl_provider)
      end
    end)
  end

  test "provider/0 defaults to the Spider adapter" do
    Application.delete_env(:magus, :crawl_provider)
    assert Crawl.provider() == Magus.Capabilities.Crawl.Spider
  end

  test "configured?/0 reflects the configured provider" do
    Application.put_env(:magus, :crawl_provider, FakeProvider)
    assert Crawl.configured?()

    Application.put_env(:magus, :crawl_provider, UnconfiguredProvider)
    refute Crawl.configured?()
  end

  test "fetch/2 delegates to the configured provider when configured" do
    Application.put_env(:magus, :crawl_provider, FakeProvider)
    assert {:ok, [result]} = Crawl.fetch(["https://example.com"], crawl_depth: 1)
    assert result.urls == ["https://example.com"]
    assert result.opts == [crawl_depth: 1]
  end

  test "fetch/2 returns {:error, :not_configured} when the provider is not configured" do
    Application.put_env(:magus, :crawl_provider, UnconfiguredProvider)
    assert {:error, :not_configured} = Crawl.fetch(["https://example.com"])
  end
end
