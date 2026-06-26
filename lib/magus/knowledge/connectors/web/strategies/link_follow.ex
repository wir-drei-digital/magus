defmodule Magus.Knowledge.Connectors.Web.Strategies.LinkFollow do
  @moduledoc """
  Discovery strategy that crawls pages by following `<a href>` links (BFS).

  Starting from the connection's `seed_url`, each `discover/3` call pops a
  batch of URLs from the frontier, returns them as discovered items, then
  fetches each page to extract new links and enqueue them onto the frontier.

  ## Cursor format

  The cursor persisted between calls is:

      %{
        "frontier"         => ["https://example.com/page2", ...],
        "depth_map"        => %{"https://example.com/page2" => 2},
        "pages_discovered" => 5
      }

  The *visited* set is NOT stored here — callers reconstruct it from existing
  File records and pass it via `collection_settings["__visited__"]`.

  ## Stopping conditions

  - Frontier is empty
  - `pages_discovered >= max_pages`
  - All frontier URLs exceed `max_depth`
  """

  @behaviour Magus.Knowledge.Connectors.Web.Strategies.Strategy

  alias Magus.Knowledge.Connectors.Web.Boundary

  require Logger

  @batch_size 20

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Pops a batch from the frontier, returns them as `{:ok, items, cursor}`.

  Each item has the shape `%{url: url, metadata: %{depth: depth}}`.

  After emitting items, the function fetches each page and enqueues newly
  discovered links onto the frontier.  Returns `{:ok, [], nil}` once the
  frontier is empty or a stopping condition is met.
  """
  @impl true
  def discover(connection, collection_settings, cursor) do
    cursor = cursor || initial_cursor(connection.seed_url)

    max_pages = Map.get(collection_settings, "max_pages", 100)
    max_depth = Map.get(collection_settings, "max_depth", 3)
    pages_discovered = cursor["pages_discovered"] || 0

    cond do
      cursor["frontier"] == [] ->
        {:ok, [], nil}

      pages_discovered >= max_pages ->
        {:ok, [], nil}

      true ->
        remaining = max_pages - pages_discovered
        batch_limit = min(@batch_size, remaining)

        {batch, cursor_after_pop} = pop_batch(cursor, batch_limit)

        # Filter out URLs that exceed max_depth
        valid_batch =
          Enum.filter(batch, fn {_url, depth} ->
            depth <= max_depth
          end)

        if valid_batch == [] do
          {:ok, [], nil}
        else
          visited = get_visited(collection_settings)

          # Build items for callers
          items =
            Enum.map(valid_batch, fn {url, depth} ->
              %{url: url, metadata: %{depth: depth}}
            end)

          # Fetch pages and discover new links
          new_cursor =
            Enum.reduce(valid_batch, cursor_after_pop, fn {url, depth}, acc_cursor ->
              fetch_and_enqueue(
                url,
                depth,
                connection,
                collection_settings,
                visited,
                acc_cursor,
                max_pages
              )
            end)

          new_pages_discovered = new_cursor["pages_discovered"] + length(valid_batch)
          final_cursor = %{new_cursor | "pages_discovered" => new_pages_discovered}

          if final_cursor["frontier"] == [] do
            {:ok, items, nil}
          else
            {:ok, items, final_cursor}
          end
        end
    end
  end

  @doc """
  Extracts all `<a href>` links from `html`, resolved against `base_url`.

  Excludes:
  - `mailto:` links
  - `javascript:` links
  - Fragment-only links (e.g. `#section`)
  """
  @spec extract_links(String.t(), String.t()) :: [String.t()]
  def extract_links(html, base_url) when is_binary(html) and is_binary(base_url) do
    case Floki.parse_document(html) do
      {:ok, doc} ->
        doc
        |> Floki.find("a")
        |> Floki.attribute("href")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&skip_href?/1)
        |> Enum.map(&resolve_url(&1, base_url))
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  @doc """
  Creates the initial cursor for a crawl starting at `seed_url` (depth 0).
  """
  @spec initial_cursor(String.t()) :: map()
  def initial_cursor(seed_url) when is_binary(seed_url) do
    %{
      "frontier" => [seed_url],
      "depth_map" => %{seed_url => 0},
      "pages_discovered" => 0
    }
  end

  @doc """
  Pops up to `batch_size` URLs from the frontier.

  Returns `{batch, updated_cursor}` where `batch` is a list of
  `{url, depth}` tuples and `updated_cursor` has the popped URLs removed.
  """
  @spec pop_batch(map(), pos_integer()) :: {[{String.t(), non_neg_integer()}], map()}
  def pop_batch(cursor, batch_size) when is_map(cursor) and is_integer(batch_size) do
    frontier = cursor["frontier"] || []
    depth_map = cursor["depth_map"] || %{}

    {popped, remaining} = Enum.split(frontier, batch_size)

    batch = Enum.map(popped, fn url -> {url, Map.get(depth_map, url, 0)} end)

    cleaned_depth_map = Map.drop(depth_map, popped)
    updated_cursor = %{cursor | "frontier" => remaining, "depth_map" => cleaned_depth_map}

    {batch, updated_cursor}
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp skip_href?(""), do: true
  defp skip_href?("#" <> _), do: true
  defp skip_href?("mailto:" <> _), do: true
  defp skip_href?("javascript:" <> _), do: true
  defp skip_href?(_), do: false

  defp resolve_url(href, base_url) do
    base_uri = URI.parse(base_url)
    href_uri = URI.parse(href)

    resolved =
      if href_uri.scheme in ["http", "https"] do
        href
      else
        URI.merge(base_uri, href_uri) |> URI.to_string()
      end

    case URI.parse(resolved) do
      %URI{scheme: scheme} when scheme in ["http", "https"] -> resolved
      _ -> nil
    end
  end

  defp get_visited(%{"__visited__" => visited}) when is_struct(visited, MapSet), do: visited
  defp get_visited(_), do: MapSet.new()

  defp fetch_and_enqueue(url, depth, connection, collection_settings, visited, cursor, max_pages) do
    max_depth = Map.get(collection_settings, "max_depth", 3)
    next_depth = depth + 1

    # Don't fetch if next depth would exceed max_depth
    if next_depth > max_depth do
      cursor
    else
      case fetch_html(url, connection.auth_headers) do
        {:ok, html} ->
          new_links = extract_links(html, url)
          frontier_cap = max_pages * 2

          initial_frontier_len = length(cursor["frontier"] || [])

          {final_cursor, _} =
            Enum.reduce(new_links, {cursor, initial_frontier_len}, fn link,
                                                                      {acc_cursor, frontier_len} ->
              normalized = Boundary.normalize(link)
              current_frontier = acc_cursor["frontier"] || []
              current_depth_map = acc_cursor["depth_map"] || %{}

              already_visited = MapSet.member?(visited, normalized)
              already_in_depth_map = Map.has_key?(current_depth_map, normalized)
              frontier_full = frontier_len >= frontier_cap

              allowed =
                Boundary.allowed?(
                  normalized,
                  collection_settings,
                  connection.robots_rules,
                  next_depth
                )

              if allowed and not already_visited and not already_in_depth_map and
                   not frontier_full do
                updated = %{
                  acc_cursor
                  | "frontier" => current_frontier ++ [normalized],
                    "depth_map" => Map.put(current_depth_map, normalized, next_depth)
                }

                {updated, frontier_len + 1}
              else
                {acc_cursor, frontier_len}
              end
            end)

          final_cursor

        {:error, reason} ->
          Logger.debug(
            "LinkFollowStrategy: failed to fetch #{url} for link extraction: #{inspect(reason)}"
          )

          cursor
      end
    end
  end

  defp fetch_html(url, auth_headers) do
    headers = if is_list(auth_headers), do: auth_headers, else: []

    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: status, body: body, headers: resp_headers}} when status in 200..299 ->
        if html_content_type?(resp_headers) do
          {:ok, body}
        else
          {:error, :not_html}
        end

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:transport_error, reason}}
    end
  end

  defp html_content_type?(headers) when is_map(headers) do
    content_type =
      headers
      |> Map.get("content-type", [""])
      |> List.first("")

    String.contains?(content_type, "text/html") or
      String.contains?(content_type, "application/xhtml")
  end

  defp html_content_type?(headers) when is_list(headers) do
    Enum.any?(headers, fn
      {key, val} when is_binary(key) and is_binary(val) ->
        String.downcase(key) == "content-type" and
          (String.contains?(val, "text/html") or String.contains?(val, "application/xhtml"))

      _ ->
        false
    end)
  end

  defp html_content_type?(_), do: false
end
