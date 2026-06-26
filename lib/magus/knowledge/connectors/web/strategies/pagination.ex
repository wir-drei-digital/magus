defmodule Magus.Knowledge.Connectors.Web.Strategies.Pagination do
  @moduledoc """
  Discovery strategy for paginated APIs.

  Supports two pagination modes:

  - `link_header` — Follows standard `Link: <url>; rel="next"` HTTP headers.
    Each page URL is itself a discovered item.

  - `json_cursor` — Extracts the next-page URL from a JSON response body using
    a dot-separated path (e.g. `"pagination.next"`).

  ## Config format (under `collection_settings["pagination"]`)

      %{
        "mode" => "link_header",           # or "json_cursor"
        "next_cursor_path" => "pagination.next"  # for json_cursor mode only
      }

  ## Cursor format

      %{"next_url" => "https://api.example.com/v1/pages?page=2", "page" => 1}

  The first call uses `connection.seed_url`. Subsequent calls use `cursor["next_url"]`.

  Respects `max_pages` from boundary config (default 500).
  """

  @behaviour Magus.Knowledge.Connectors.Web.Strategies.Strategy

  alias Magus.Knowledge.Connectors.Web.Boundary

  require Logger

  @default_max_pages 500

  @doc """
  Fetches the current page URL, extracts items, and determines the next cursor.

  Returns `{:ok, entries, cursor}` where `cursor` is `nil` when there are no
  more pages.
  """
  @impl true
  def discover(connection, collection_settings, cursor) do
    max_pages = get_in(collection_settings, ["boundary", "max_pages"]) || @default_max_pages
    page = if cursor, do: Map.get(cursor, "page", 0), else: 0

    if page >= max_pages do
      {:ok, [], nil}
    else
      current_url = if cursor, do: cursor["next_url"], else: connection.seed_url
      pagination_config = Map.get(collection_settings, "pagination", %{}) || %{}
      mode = Map.get(pagination_config, "mode", "link_header")

      case fetch_page(current_url, connection.auth_headers) do
        {:ok, body, headers} ->
          entry = build_entry(current_url, page)

          allowed_entry =
            if Boundary.allowed?(current_url, collection_settings, connection.robots_rules, 0) do
              [%{entry | url: Boundary.normalize(entry.url)}]
            else
              []
            end

          next_cursor = extract_next_cursor(mode, headers, body, pagination_config, page)
          {:ok, allowed_entry, next_cursor}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Parses a Link header value and returns the URL for `rel="next"`, or `nil` if not found.

  Handles multiple link entries separated by commas and extra whitespace.
  """
  @spec parse_link_header(String.t() | nil) :: String.t() | nil
  def parse_link_header(nil), do: nil
  def parse_link_header(""), do: nil

  def parse_link_header(header) when is_binary(header) do
    header
    |> String.split(",")
    |> Enum.find_value(nil, fn segment ->
      parse_link_segment(String.trim(segment))
    end)
  end

  @doc """
  Extracts the value at a dot-separated `path` from a JSON `body` map.

  Returns `nil` if the path does not exist, the value is `nil`, or the value is an empty string.
  """
  @spec extract_cursor_from_json(map() | nil, String.t()) :: String.t() | nil
  def extract_cursor_from_json(nil, _path), do: nil

  def extract_cursor_from_json(body, path) when is_map(body) and is_binary(path) do
    keys = String.split(path, ".")

    result =
      Enum.reduce_while(keys, body, fn key, acc ->
        cond do
          is_map(acc) ->
            case Map.get(acc, key) do
              nil -> {:halt, nil}
              val -> {:cont, val}
            end

          true ->
            {:halt, nil}
        end
      end)

    case result do
      nil -> nil
      "" -> nil
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  def extract_cursor_from_json(_body, _path), do: nil

  # --- Private helpers ---

  defp fetch_page(url, auth_headers) do
    headers = build_headers(auth_headers)

    case Req.get(url, headers: headers, retry: :transient) do
      {:ok, %{status: status, body: body, headers: resp_headers}} when status in 200..299 ->
        {:ok, body, resp_headers}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_headers(auth_headers) when is_list(auth_headers), do: auth_headers
  defp build_headers(auth_headers) when is_map(auth_headers), do: Map.to_list(auth_headers)
  defp build_headers(_), do: []

  defp build_entry(url, page) do
    %{url: url, metadata: %{page: page}}
  end

  defp extract_next_cursor("link_header", headers, _body, _pagination_config, page) do
    link_value = extract_link_header(headers)

    case parse_link_header(link_value) do
      nil -> nil
      next_url -> %{"next_url" => next_url, "page" => page + 1}
    end
  end

  defp extract_next_cursor("json_cursor", _headers, body, pagination_config, page) do
    cursor_path = Map.get(pagination_config, "next_cursor_path")

    if is_nil(cursor_path) do
      Logger.warning("PaginationStrategy: json_cursor mode requires next_cursor_path config")
      nil
    else
      decoded_body = decode_body_if_needed(body)

      case extract_cursor_from_json(decoded_body, cursor_path) do
        nil -> nil
        next_url -> %{"next_url" => next_url, "page" => page + 1}
      end
    end
  end

  defp extract_next_cursor(_mode, _headers, _body, _config, _page), do: nil

  # Req 0.5+ returns headers as %{String.t() => [String.t()]}
  # Older versions return keyword list or list of tuples
  defp extract_link_header(headers) when is_map(headers) do
    headers
    |> Map.get("link", [])
    |> List.first()
  end

  defp extract_link_header(headers) when is_list(headers) do
    Enum.find_value(headers, nil, fn
      {key, val} when is_binary(key) and is_binary(val) ->
        if String.downcase(key) == "link", do: val, else: nil

      _ ->
        nil
    end)
  end

  defp extract_link_header(_), do: nil

  defp decode_body_if_needed(body) when is_map(body), do: body
  defp decode_body_if_needed(body) when is_list(body), do: body

  defp decode_body_if_needed(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _} -> nil
    end
  end

  defp decode_body_if_needed(_), do: nil

  defp parse_link_segment(segment) do
    # A segment looks like: <https://...>; rel="next"
    # We match <URL> and then look for rel="next"
    with [url_part, rel_part | _] <- String.split(segment, ";", parts: 2),
         url when not is_nil(url) <- extract_url_from_angle_brackets(String.trim(url_part)),
         true <- rel_is_next?(String.trim(rel_part)) do
      url
    else
      _ -> nil
    end
  end

  defp extract_url_from_angle_brackets(s) do
    case Regex.run(~r/^<(.+)>$/, s) do
      [_, url] -> url
      _ -> nil
    end
  end

  defp rel_is_next?(rel_str) do
    # rel="next" or rel=next (with possible extra attributes after semicolons)
    rel_str
    |> String.split(";")
    |> Enum.any?(fn part ->
      part
      |> String.trim()
      |> String.downcase()
      |> then(&(&1 == ~s(rel="next") or &1 == "rel=next"))
    end)
  end
end
