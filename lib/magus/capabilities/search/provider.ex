defmodule Magus.Capabilities.Search.Provider do
  @moduledoc """
  Behaviour for web-search capability adapters (the open-core capability seam).

  An adapter wraps a search backend (Exa today) and is selected via
  `:magus, :search_provider`. The dispatcher `Magus.Capabilities.Search` gates
  the `web_search` tool off when no adapter reports `configured?/0`, so a
  self-host instance without a search key simply does not offer it.

  External adapters can be added later by implementing this behaviour and
  pointing the config at them; no provider packaging is built yet.
  """

  @type result :: %{
          optional(:title) => String.t() | nil,
          optional(:url) => String.t() | nil,
          optional(:summary) => String.t() | nil,
          optional(:published_date) => String.t() | nil
        }

  @doc "Whether this adapter has the credentials/config it needs to run."
  @callback configured?() :: boolean()

  @doc """
  Run a search. Recognised options: `:num_results` (integer), `:category`
  (string). Returns `{:ok, results}` or `{:error, reason}`.
  """
  @callback search(query :: String.t(), opts :: keyword()) ::
              {:ok, [result()]} | {:error, term()}
end
