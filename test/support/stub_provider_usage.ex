defmodule Magus.Test.StubProviderUsage do
  @moduledoc """
  Test stub for `Magus.Agents.Providers.ProviderUsage`.

  Returns no usage results so the admin Providers LiveView renders its
  no-data state without making real network calls to provider billing APIs.
  Wired in via `config :magus, :provider_usage_fetcher` in `config/test.exs`.
  """

  @spec fetch_all() :: list(map())
  def fetch_all, do: []
end
