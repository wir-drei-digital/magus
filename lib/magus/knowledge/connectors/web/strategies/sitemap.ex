defmodule Magus.Knowledge.Connectors.Web.Strategies.Sitemap do
  @moduledoc """
  Discovery strategy that uses XML sitemaps to enumerate URLs.

  Fetches the sitemap from `connection.seed_url`, handles both regular sitemaps
  and sitemap index files (sitemaps of sitemaps), and filters discovered URLs
  through `Boundary.allowed?/4` and `Boundary.normalize/1`.

  No cursor pagination is needed — all URLs are returned in a single pass.
  """

  @behaviour Magus.Knowledge.Connectors.Web.Strategies.Strategy

  import SweetXml

  alias Magus.Knowledge.Connectors.Web.Boundary

  require Logger

  @doc """
  Discovers all URLs from the sitemap at `connection.seed_url`.

  Handles sitemap index files by fetching each child sitemap and aggregating
  results. All URLs are filtered through `Boundary.allowed?/4` before being
  returned.

  Returns `{:ok, entries, nil}` — sitemap discovery is always single-pass.
  """
  @impl true
  def discover(connection, collection_settings, _cursor) do
    with {:ok, body} <- fetch_url(connection.seed_url, connection.auth_headers) do
      entries =
        if is_sitemap_index?(body) do
          body
          |> parse_sitemap_index()
          |> Enum.flat_map(fn child_url ->
            case fetch_url(child_url, connection.auth_headers) do
              {:ok, child_body} ->
                parse_sitemap(child_body)

              {:error, reason} ->
                Logger.warning("Failed to fetch child sitemap #{child_url}: #{inspect(reason)}")
                []
            end
          end)
        else
          parse_sitemap(body)
        end

      allowed =
        entries
        |> Enum.filter(fn %{url: url} ->
          Boundary.allowed?(url, collection_settings, connection.robots_rules, 0)
        end)
        |> Enum.map(fn %{url: url} = entry ->
          %{entry | url: Boundary.normalize(url)}
        end)

      {:ok, allowed, nil}
    end
  end

  @doc """
  Parses a sitemap XML body and returns a list of URL entries.

  Each entry is a map with `:url` (string) and `:metadata` (map containing
  `:lastmod` if present, otherwise `nil`).
  """
  @spec parse_sitemap(String.t()) :: [%{url: String.t(), metadata: map()}]
  def parse_sitemap(body) when is_binary(body) do
    try do
      body
      |> xpath(~x"//url"l,
        loc: ~x"./loc/text()"s,
        lastmod: ~x"./lastmod/text()"so
      )
      |> Enum.map(fn %{loc: loc, lastmod: lastmod} ->
        normalized_lastmod = if lastmod == "" or lastmod == nil, do: nil, else: lastmod
        %{url: loc, metadata: %{"last_modified" => normalized_lastmod}}
      end)
    catch
      :exit, _ -> []
      _, _ -> []
    end
  end

  @doc """
  Parses a sitemap index XML body and returns a list of child sitemap URLs.
  """
  @spec parse_sitemap_index(String.t()) :: [String.t()]
  def parse_sitemap_index(body) when is_binary(body) do
    try do
      body
      |> xpath(~x"//sitemap/loc/text()"sl)
    catch
      :exit, _ -> []
      _, _ -> []
    end
  end

  @doc """
  Returns `true` if the given XML body is a sitemap index (contains `<sitemapindex`).
  """
  @spec is_sitemap_index?(String.t()) :: boolean()
  def is_sitemap_index?(body) when is_binary(body) do
    String.contains?(body, "<sitemapindex")
  end

  # --- Private helpers ---

  defp fetch_url(url, auth_headers) do
    headers = if is_list(auth_headers), do: auth_headers, else: []

    case Req.get(url, headers: headers, retry: :transient) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
