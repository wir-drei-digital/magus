defmodule Magus.Capabilities.Crawl do
  @moduledoc """
  Web crawl/fetch capability dispatcher for the open-core split.

  Resolves the adapter from `:magus, :crawl_provider` (default
  `Magus.Capabilities.Crawl.Spider`, opt-in via `SPIDER_API_KEY`) and delegates
  to it. `configured?/0` lets agent tool registration gate the `web_fetch` tool
  off when no provider is set up.
  """

  @default_provider Magus.Capabilities.Crawl.Spider

  @doc "The configured crawl adapter module."
  @spec provider() :: module()
  def provider, do: Application.get_env(:magus, :crawl_provider, @default_provider)

  @doc "Whether the configured adapter is ready to fetch."
  @spec configured?() :: boolean()
  def configured? do
    provider = provider()
    is_atom(provider) and not is_nil(provider) and provider.configured?()
  end

  @doc """
  Fetch URLs via the configured adapter, or `{:error, :not_configured}` when
  none is set up. Options: `:crawl_depth`, `:crawl_limit`, `:return_format`,
  `:max_content_length`.
  """
  @spec fetch([String.t()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch(urls, opts \\ []) do
    if configured?() do
      provider().fetch(urls, opts)
    else
      {:error, :not_configured}
    end
  end
end
