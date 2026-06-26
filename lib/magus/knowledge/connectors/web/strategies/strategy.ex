defmodule Magus.Knowledge.Connectors.Web.Strategies.Strategy do
  @moduledoc """
  Behaviour for web knowledge connector discovery strategies.

  Each strategy implements a different method of discovering URLs from a web source
  (e.g., sitemap, OpenAPI spec, pagination, link-following).
  """

  @doc """
  Discovers URLs from the given connection.

  Returns a list of URL entries (each with `:url` and `:metadata` keys), along with
  a cursor for the next page (or `nil` if discovery is complete in one pass).

  ## Parameters

  - `connection` - Connection struct with `seed_url`, `auth_headers`, and `robots_rules`
  - `collection_settings` - Map of boundary/filter settings (allowed_domains, excluded_paths, etc.)
  - `cursor` - Opaque map for resuming paginated discovery, or `nil` for a fresh run

  ## Return values

  - `{:ok, entries, nil}` - All URLs discovered; no further pages
  - `{:ok, entries, cursor}` - Partial results; call again with `cursor` for the next page
  - `{:error, reason}` - Discovery failed
  """
  @callback discover(
              connection :: term(),
              collection_settings :: map(),
              cursor :: map() | nil
            ) ::
              {:ok, [%{url: String.t(), metadata: map()}], new_cursor :: map() | nil}
              | {:error, term()}
end
