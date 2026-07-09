defmodule Magus.Knowledge.Connectors.Web do
  @moduledoc """
  Web knowledge source connector.

  Connects to arbitrary web sources using auto-detected or explicit discovery
  strategies (sitemap, OpenAPI, pagination, link-following).

  Supports bearer token, API key, and basic HTTP authentication.
  """

  @behaviour Magus.Knowledge.Connector

  require Logger

  alias Magus.Knowledge.Connectors.Web.AutoDetector
  alias Magus.Knowledge.Connectors.Web.Fetcher

  defstruct [
    :seed_url,
    :strategy,
    :strategy_module,
    :boundary,
    :auth_headers,
    :use_spider,
    :robots_rules,
    :crawl_delay_ms
  ]

  @doc """
  Establishes a connection to the web source described by `auth_config`.

  ## Auth config fields

    * `"seed_url"` - (required) The starting URL
    * `"strategy"` - `"auto"`, `"sitemap"`, `"openapi"`, `"pagination"`, or `"link_follow"` (default: `"auto"`)
    * `"auth_type"` - `"none"`, `"bearer"`, `"api_key"`, or `"basic"` (default: `"none"`)
    * `"token"` - Bearer token (when `auth_type` is `"bearer"`)
    * `"api_key"` - API key value (when `auth_type` is `"api_key"`)
    * `"api_key_header"` - Header name for API key (default: `"X-Api-Key"`)
    * `"username"` / `"password"` - Credentials (when `auth_type` is `"basic"`)

  """
  @impl true
  def connect(auth_config) when is_map(auth_config) do
    seed_url = Map.get(auth_config, "seed_url")

    if is_binary(seed_url) and seed_url != "" do
      auth_headers = build_auth_headers(auth_config)
      strategy_override = Map.get(auth_config, "strategy", "auto")
      explicit_module = AutoDetector.strategy_for_override(strategy_override)

      {strategy_module, robots_rules, crawl_delay_ms} =
        if is_nil(explicit_module) do
          try do
            {:ok, mod, rules, delay} = AutoDetector.detect(seed_url, auth_headers)
            {mod, rules, delay}
          rescue
            e ->
              Logger.warning(
                "AutoDetector raised for #{seed_url}: #{inspect(e)}, falling back to LinkFollow"
              )

              {Magus.Knowledge.Connectors.Web.Strategies.LinkFollow, [], nil}
          end
        else
          {explicit_module, [], nil}
        end

      conn = %__MODULE__{
        seed_url: seed_url,
        strategy: strategy_override,
        strategy_module: strategy_module,
        boundary: nil,
        auth_headers: auth_headers,
        use_spider: Map.get(auth_config, "use_spider", true),
        robots_rules: robots_rules,
        crawl_delay_ms: crawl_delay_ms
      }

      {:ok, conn}
    else
      {:error, :missing_seed_url}
    end
  end

  @doc """
  Returns a single top-level folder representing the web source.
  """
  @impl true
  def list_folders(%__MODULE__{seed_url: seed_url}, _path) do
    {:ok, [%{id: seed_url, name: "Web Source", path: "/"}]}
  end

  @doc """
  Discovers items by delegating to the strategy module.

  Each discovered URL is translated to a `Connector.item()` map with
  `mime_type: "text/markdown"` and `etag: nil` (content hash is computed
  during `fetch_content/2`).
  """
  @impl true
  def list_items(%__MODULE__{} = conn, collection, cursor) do
    case conn.strategy_module.discover(conn, collection.settings || %{}, cursor) do
      {:ok, entries, new_cursor} ->
        items = Enum.map(entries, &translate_item/1)
        {:ok, items, new_cursor}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches content for a single item.

  For OpenAPI spec-only items that have pre-rendered content in `:spec_content`
  metadata, returns the content directly without making an HTTP request.

  For all other items, delegates to `Fetcher.fetch/2` and includes the
  content hash as `"etag"` in the returned metadata.
  """
  @impl true
  def fetch_content(%__MODULE__{} = conn, item) do
    metadata = Map.get(item, :metadata, %{}) || %{}
    spec_content = Map.get(metadata, :spec_content)

    if is_binary(spec_content) do
      hash = Fetcher.content_hash(spec_content)

      {:ok, spec_content,
       %{
         "etag" => hash,
         "fetched_at" => DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    else
      url = item.id
      rate_delay = conn.crawl_delay_ms || 500

      fetch_opts = [
        auth_headers: conn.auth_headers || [],
        rate_delay: rate_delay
      ]

      case Fetcher.fetch(url, fetch_opts) do
        {:ok, content, fetch_metadata} ->
          hash = Map.get(fetch_metadata, "content_hash")
          merged_metadata = Map.put(fetch_metadata, "etag", hash)
          {:ok, content, merged_metadata}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Change detection is not supported for web sources.
  """
  @impl true
  def detect_changes(_conn, _collection, _since), do: {:error, :not_supported}

  @doc """
  Webhooks are not supported for web sources.
  """
  @impl true
  def register_webhook(_conn, _collection, _callback_url), do: {:error, :not_supported}

  @doc """
  Creating items is not supported — web connectors are read-only.
  """
  @impl true
  def create_item(_conn, _collection, _name, _content, _metadata), do: {:error, :not_supported}

  @doc """
  Updating items is not supported — web connectors are read-only.
  """
  @impl true
  def update_item(_conn, _collection, _external_id, _content, _metadata),
    do: {:error, :not_supported}

  @doc """
  Builds HTTP auth headers from the `auth_config` map.

  Supported `auth_type` values:

    * `"bearer"` - Adds `Authorization: Bearer <token>` header
    * `"api_key"` - Adds `<api_key_header>: <api_key>` (default header: `X-Api-Key`)
    * `"basic"` - Adds `Authorization: Basic <base64(username:password)>` header
    * `"none"` / missing - Returns empty list

  """
  @spec build_auth_headers(map()) :: list()
  def build_auth_headers(auth_config) when is_map(auth_config) do
    case Map.get(auth_config, "auth_type", "none") do
      "bearer" ->
        token = Map.get(auth_config, "token", "")
        [{"Authorization", "Bearer #{token}"}]

      "api_key" ->
        key = Map.get(auth_config, "api_key", "")
        header_name = Map.get(auth_config, "api_key_header", "X-Api-Key")
        [{header_name, key}]

      "basic" ->
        username = Map.get(auth_config, "username", "")
        password = Map.get(auth_config, "password", "")
        credentials = Base.encode64("#{username}:#{password}")
        [{"Authorization", "Basic #{credentials}"}]

      _ ->
        []
    end
  end

  def build_auth_headers(_), do: []

  @doc """
  Translates a strategy discovery entry to a `Connector.item()` map.

  Strategy entries have the shape `%{url: String.t(), metadata: map()}`.

  The item ID is the normalized URL. The name is taken from
  `metadata["title"]` if present, otherwise derived from the URL path.
  Datetime strings in `metadata["last_modified"]` are parsed to
  `DateTime.t()` when possible and also serve as the list-time etag,
  allowing unchanged pages to be skipped without fetching.
  """
  @spec translate_item(%{url: String.t(), metadata: map()}) :: Magus.Knowledge.Connector.item()
  def translate_item(%{url: url, metadata: metadata}) do
    name = extract_name(url, metadata)
    updated_at = parse_datetime(Map.get(metadata, "last_modified"))

    %{
      id: url,
      name: name,
      etag: Map.get(metadata, "last_modified"),
      updated_at: updated_at,
      mime_type: "text/markdown",
      metadata: metadata
    }
  end

  def translate_item(%{url: url}) do
    translate_item(%{url: url, metadata: %{}})
  end

  # --- Private helpers ---

  defp extract_name(url, metadata) when is_map(metadata) do
    cond do
      is_binary(Map.get(metadata, "title")) and Map.get(metadata, "title") != "" ->
        Map.get(metadata, "title")

      true ->
        uri = URI.parse(url)
        path = uri.path || "/"

        path
        |> String.split("/")
        |> Enum.reject(&(&1 == ""))
        |> List.last()
        |> case do
          nil -> url
          segment -> segment
        end
    end
  end

  defp extract_name(url, _), do: url

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        dt

      {:error, _} ->
        # Try NaiveDateTime and assume UTC
        case NaiveDateTime.from_iso8601(value) do
          {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
          {:error, _} -> nil
        end
    end
  end

  defp parse_datetime(_), do: nil
end
