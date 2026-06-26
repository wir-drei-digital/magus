defmodule Magus.Capabilities.Search do
  @moduledoc """
  Web-search capability dispatcher for the open-core split.

  Resolves the adapter from `:magus, :search_provider` (default
  `Magus.Capabilities.Search.Exa`) and delegates to it. `configured?/0` lets
  callers (e.g. agent tool registration) gate the `web_search` tool off when no
  provider is set up, so a self-host instance without a search key never offers
  a tool it cannot run.

  Not to be confused with `Magus.Search`, the in-app entity search over the
  user's own messages/conversations/brain.
  """

  @default_provider Magus.Capabilities.Search.Exa

  @doc "The configured search adapter module."
  @spec provider() :: module()
  def provider, do: Application.get_env(:magus, :search_provider, @default_provider)

  @doc "Whether the configured adapter is ready to serve searches."
  @spec configured?() :: boolean()
  def configured? do
    provider = provider()
    is_atom(provider) and not is_nil(provider) and provider.configured?()
  end

  @doc """
  Run a web search via the configured adapter, or `{:error, :not_configured}`
  when none is set up. Options: `:num_results`, `:category`.
  """
  @spec search(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def search(query, opts \\ []) do
    if configured?() do
      provider().search(query, opts)
    else
      {:error, :not_configured}
    end
  end
end
