defmodule Magus.Capabilities.Crawl.Provider do
  @moduledoc """
  Behaviour for web crawl/fetch capability adapters (the open-core capability seam).

  An adapter wraps a scraping/crawling backend (Spider today) and is selected
  via `:magus, :crawl_provider`. The dispatcher `Magus.Capabilities.Crawl` gates
  the `web_fetch` tool off when no adapter reports `configured?/0`.
  """

  @type result :: %{
          optional(:url) => String.t() | nil,
          optional(:status) => integer() | nil,
          optional(:title) => String.t() | nil,
          optional(:description) => String.t() | nil,
          optional(:content) => String.t() | nil,
          optional(:error) => term()
        }

  @doc "Whether this adapter has the credentials/config it needs to run."
  @callback configured?() :: boolean()

  @doc """
  Fetch one or more URLs. Recognised options: `:crawl_depth` (0 = scrape),
  `:crawl_limit`, `:return_format`, `:max_content_length`. Returns
  `{:ok, results}` or `{:error, reason}`.
  """
  @callback fetch(urls :: [String.t()], opts :: keyword()) ::
              {:ok, [result()]} | {:error, term()}
end
