defmodule Magus.Knowledge.Connectors.Webdav.Client do
  @moduledoc """
  Shared, connection-agnostic WebDAV client.

  Owns the generic WebDAV mechanics reused by every WebDAV-backed connector
  (Nextcloud, generic WebDAV, etc.): `PROPFIND`/`GET` requests, 429/503 retry
  with `Retry-After`, `multistatus` XML parsing, WebDAV date parsing, and the
  href/path encoding helpers.

  This module knows nothing about a specific provider's authentication config
  shape or path-prefix conventions. Callers pass a fully-built `base_url`, the
  auth headers, and an absolute WebDAV `path`; the client does no path magic.

  Uses recursive `Depth: 1` PROPFIND requests instead of `Depth: infinity`
  for compatibility — many WebDAV servers disable infinite depth.

  Handles 429/503 rate limiting with automatic retry using the `Retry-After`
  header.
  """

  require Logger

  @doc """
  Perform a `PROPFIND` at `base_url <> path` with the given `auth_headers` and
  `depth`.

  Returns `{:ok, body}` for a 200/207 response, `{:error, {:webdav_error, status,
  body}}` for other statuses, or `{:error, {:request_failed, reason}}`.
  """
  def propfind(base_url, auth_headers, path, depth)
      when is_binary(base_url) and is_list(auth_headers) and is_binary(path) and is_integer(depth) do
    url = base_url <> path

    depth_header = Integer.to_string(depth)

    propfind_body = """
    <?xml version="1.0" encoding="UTF-8"?>
    <d:propfind xmlns:d="DAV:">
      <d:prop>
        <d:displayname/>
        <d:getlastmodified/>
        <d:getcontenttype/>
        <d:getetag/>
        <d:resourcetype/>
        <d:getcontentlength/>
      </d:prop>
    </d:propfind>
    """

    headers =
      [
        {"depth", depth_header},
        {"content-type", "application/xml; charset=utf-8"}
      ] ++ auth_headers

    case request_with_retry(:propfind, url, auth_headers,
           body: propfind_body,
           headers: headers,
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 207] ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("WebDAV PROPFIND error: status=#{status} path=#{path}")
        {:error, {:webdav_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @doc """
  Issue a request with automatic retry on 429/503, honoring `Retry-After`.

  `method` is `:get` or `:propfind`. For `:get`, `auth_headers` are applied
  automatically; for `:propfind`, callers pass the full header list via
  `extra_opts`.
  """
  def request_with_retry(method, url, auth_headers, extra_opts \\ [], retries \\ 0) do
    base_opts =
      case method do
        :get ->
          [method: :get, url: url, headers: auth_headers, receive_timeout: 60_000]

        :propfind ->
          # Finch only accepts standard HTTP verbs as atoms; a WebDAV extension
          # method must be a binary.
          [method: "PROPFIND", url: url]
      end

    opts = Keyword.merge(base_opts, extra_opts)

    case Req.request(opts) do
      {:ok, %Req.Response{status: status} = response} when status in [429, 503] and retries < 3 ->
        # Capped at 15s: this sleep occupies one of only 5 global knowledge_sync
        # queue slots, so a large provider-supplied Retry-After should not stall
        # the whole queue.
        retry_after = min(retry_after_seconds(response), 15)

        Logger.warning(
          "WebDAV rate limited (#{status}), retrying in #{retry_after}s (attempt #{retries + 1}/3)"
        )

        Process.sleep(retry_after * 1_000)
        request_with_retry(method, url, auth_headers, extra_opts, retries + 1)

      result ->
        result
    end
  end

  defp retry_after_seconds(%Req.Response{} = response) do
    case Req.Response.get_header(response, "retry-after") do
      [value | _] ->
        case Integer.parse(value) do
          {seconds, _} when seconds > 0 and seconds <= 60 -> seconds
          _ -> 1
        end

      _ ->
        1
    end
  end

  @doc """
  Build the HTTP Basic `authorization` header list for `username`/`password`.
  """
  def basic_auth_headers(username, password) do
    encoded = Base.encode64("#{username}:#{password}")
    [{"authorization", "Basic #{encoded}"}]
  end

  @doc "Normalize an href for self-comparison: URI-decode and strip a trailing slash."
  def normalize_href(nil), do: ""

  def normalize_href(href) do
    href
    |> URI.decode()
    |> String.trim_trailing("/")
  end

  @doc "Percent-encode a single path component (RFC 3986 unreserved set)."
  def encode_component(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  @doc "Percent-encode each segment of a `/`-joined path, preserving separators."
  def encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &encode_component/1)
  end

  # --- XML Parsing ---
  # Regex-based parsing for WebDAV multistatus responses.
  # Handles common namespace prefixes (d:, D:, and unprefixed DAV elements).

  @doc """
  Parse a WebDAV `multistatus` body into a list of response entry maps
  (`:href`, `:display_name`, `:last_modified`, `:content_type`, `:etag`,
  `:is_collection`).
  """
  def parse_multistatus(body) when is_binary(body) do
    # Match response blocks with any namespace prefix or none
    ~r/<(?:\w+:)?response\b[^>]*>(.*?)<\/(?:\w+:)?response>/s
    |> Regex.scan(body, capture: :first)
    |> Enum.map(fn [block] -> parse_response_block(block) end)
  end

  def parse_multistatus(_), do: []

  defp parse_response_block(block) do
    %{
      href: extract_xml_value(block, "href"),
      display_name: extract_xml_value(block, "displayname"),
      last_modified: extract_xml_value(block, "getlastmodified"),
      content_type: extract_xml_value(block, "getcontenttype"),
      etag: extract_xml_value(block, "getetag"),
      is_collection: Regex.match?(~r/<(?:\w+:)?collection[\s\/>]/, block)
    }
  end

  defp extract_xml_value(block, tag) do
    # Match any namespace prefix (d:, D:, ns0:, etc.) or unprefixed
    case Regex.run(~r/<(?:\w+:)?#{tag}[^>]*>(.*?)<\/(?:\w+:)?#{tag}>/s, block) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  # --- Date parsing ---

  @doc """
  Parse a WebDAV date (`getlastmodified`) to a `DateTime`.

  Tries ISO 8601 first, then RFC 2822 (`"Sat, 22 Mar 2026 10:30:00 GMT"`).
  Falls back to the current time (with a warning) for `nil` or unparseable
  input.
  """
  def parse_datetime(nil), do: DateTime.utc_now()

  def parse_datetime(date_string) when is_binary(date_string) do
    # Try ISO 8601 first
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} ->
        dt

      _ ->
        # WebDAV uses RFC 2822 dates like "Sat, 22 Mar 2026 10:30:00 GMT"
        parse_rfc2822(date_string)
    end
  end

  @months %{
    "Jan" => 1,
    "Feb" => 2,
    "Mar" => 3,
    "Apr" => 4,
    "May" => 5,
    "Jun" => 6,
    "Jul" => 7,
    "Aug" => 8,
    "Sep" => 9,
    "Oct" => 10,
    "Nov" => 11,
    "Dec" => 12
  }

  defp parse_rfc2822(date_string) do
    # Match "Day, DD Mon YYYY HH:MM:SS GMT" format
    case Regex.run(
           ~r/\w+,\s+(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT/,
           date_string
         ) do
      [_, day, month_str, year, hour, min, sec] ->
        with month when is_integer(month) <- Map.get(@months, month_str),
             {:ok, dt} <-
               NaiveDateTime.new(
                 String.to_integer(year),
                 month,
                 String.to_integer(day),
                 String.to_integer(hour),
                 String.to_integer(min),
                 String.to_integer(sec)
               ) do
          DateTime.from_naive!(dt, "Etc/UTC")
        else
          _ ->
            Logger.warning("WebDAV: unparseable date #{inspect(date_string)}, using current time")

            DateTime.utc_now()
        end

      _ ->
        Logger.warning("WebDAV: unparseable date #{inspect(date_string)}, using current time")
        DateTime.utc_now()
    end
  end
end
