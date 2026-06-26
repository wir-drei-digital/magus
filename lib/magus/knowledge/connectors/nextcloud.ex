defmodule Magus.Knowledge.Connectors.Nextcloud do
  @moduledoc """
  Knowledge connector for Nextcloud via WebDAV.

  Uses WebDAV (PROPFIND/GET) to list folders, enumerate files, and
  fetch file content from a Nextcloud instance.

  Uses recursive `Depth: 1` PROPFIND requests instead of `Depth: infinity`
  for compatibility — many Nextcloud instances disable infinite depth.

  Handles 429/503 rate limiting with automatic retry using the `Retry-After`
  header.

  ## Auth Config

      %{"base_url" => "https://cloud.example.com", "username" => "user", "password" => "pass"}

  The password can be an app-specific password generated in Nextcloud settings.
  """

  @behaviour Magus.Knowledge.Connector

  require Logger

  @max_depth 10

  defstruct [:base_url, :username, :password]

  # --- Connector callbacks ---

  @impl true
  def connect(%{"base_url" => base_url, "username" => username, "password" => password} = _config)
      when is_binary(base_url) and base_url != "" and
             is_binary(username) and username != "" and
             is_binary(password) and password != "" do
    # Normalize base_url — strip trailing slash
    base_url = String.trim_trailing(base_url, "/")

    {:ok,
     %__MODULE__{
       base_url: base_url,
       username: username,
       password: password
     }}
  end

  def connect(_auth_config) do
    {:error, :missing_credentials}
  end

  @impl true
  def list_folders(%__MODULE__{} = conn, path) do
    webdav_path = build_webdav_path(conn, path || "/")

    case propfind(conn, webdav_path, 1) do
      {:ok, body} ->
        folders =
          body
          |> parse_multistatus()
          |> Enum.filter(
            &(&1.is_collection && normalize_href(&1.href) != normalize_href(webdav_path))
          )
          |> Enum.map(fn entry ->
            %{
              id: entry.href,
              name: entry.display_name || Path.basename(URI.decode(entry.href)),
              path: relative_path(conn, entry.href)
            }
          end)

        {:ok, folders}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_items(%__MODULE__{} = conn, collection, _cursor) do
    webdav_path = collection_path(conn, collection)

    case list_items_recursive(conn, webdav_path, 0) do
      {:ok, entries} ->
        items =
          entries
          |> Enum.reject(& &1.is_collection)
          |> Enum.map(fn entry ->
            %{
              id: entry.href,
              name: entry.display_name || Path.basename(URI.decode(entry.href)),
              etag: entry.etag || "",
              updated_at: parse_datetime(entry.last_modified),
              mime_type: entry.content_type || "application/octet-stream"
            }
          end)

        # WebDAV has no cursor-based pagination — return all items
        {:ok, items, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_items_recursive(_conn, _path, depth) when depth >= @max_depth, do: {:ok, []}

  defp list_items_recursive(conn, webdav_path, depth) do
    case propfind(conn, webdav_path, 1) do
      {:ok, body} ->
        entries = parse_multistatus(body)

        # Separate files from subdirectories (exclude self)
        normalized_self = normalize_href(webdav_path)

        {subdirs, files} =
          entries
          |> Enum.reject(&(normalize_href(&1.href) == normalized_self))
          |> Enum.split_with(& &1.is_collection)

        # Recurse into subdirectories, accumulating with prepend
        child_results =
          Enum.reduce_while(subdirs, {:ok, []}, fn subdir, {:ok, acc} ->
            case list_items_recursive(conn, subdir.href, depth + 1) do
              {:ok, children} -> {:cont, {:ok, [children | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case child_results do
          {:ok, children} -> {:ok, files ++ (children |> Enum.reverse() |> List.flatten())}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_content(%__MODULE__{} = conn, item) do
    path = item_path(item)
    url = conn.base_url <> path

    case request_with_retry(:get, url, conn) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        metadata = %{"path" => path, "format" => "raw"}
        {:ok, body, metadata}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Nextcloud GET error: status=#{status} path=#{path}")
        {:error, {:webdav_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def detect_changes(_conn, _collection, _since) do
    # WebDAV has no delta/changes API
    {:error, :not_supported}
  end

  @impl true
  def register_webhook(_conn, _collection, _callback_url) do
    {:error, :not_supported}
  end

  @impl true
  def create_item(_conn, _collection, _name, _content, _metadata) do
    {:error, :not_supported}
  end

  @impl true
  def update_item(_conn, _collection, _external_id, _content, _metadata) do
    {:error, :not_supported}
  end

  # --- Private helpers ---

  defp propfind(%__MODULE__{} = conn, path, depth) do
    url = conn.base_url <> path

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
      ] ++ auth_headers(conn)

    case request_with_retry(:propfind, url, conn,
           body: propfind_body,
           headers: headers,
           receive_timeout: 30_000
         ) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 207] ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Nextcloud PROPFIND error: status=#{status} path=#{path}")
        {:error, {:webdav_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp request_with_retry(method, url, conn, extra_opts \\ [], retries \\ 0) do
    base_opts =
      case method do
        :get ->
          [method: :get, url: url, headers: auth_headers(conn), receive_timeout: 60_000]

        :propfind ->
          [method: :propfind, url: url]
      end

    opts = Keyword.merge(base_opts, extra_opts)

    case Req.request(opts) do
      {:ok, %Req.Response{status: status} = response} when status in [429, 503] and retries < 3 ->
        retry_after = retry_after_seconds(response)

        Logger.warning(
          "Nextcloud rate limited (#{status}), retrying in #{retry_after}s (attempt #{retries + 1}/3)"
        )

        Process.sleep(retry_after * 1_000)
        request_with_retry(method, url, conn, extra_opts, retries + 1)

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

  defp auth_headers(%__MODULE__{username: username, password: password}) do
    encoded = Base.encode64("#{username}:#{password}")
    [{"authorization", "Basic #{encoded}"}]
  end

  defp build_webdav_path(%__MODULE__{username: username}, path) do
    base = "/remote.php/dav/files/" <> encode_component(username)
    path = String.trim_leading(path, "/")

    if path == "" do
      base <> "/"
    else
      base <> "/" <> encode_path(path) <> "/"
    end
  end

  defp collection_path(conn, collection) do
    path =
      case collection do
        %{path: p} when is_binary(p) -> p
        %{"path" => p} when is_binary(p) -> p
        %{external_id: id} when is_binary(id) -> id
        %{"external_id" => id} when is_binary(id) -> id
        _ -> "/"
      end

    # If path already contains /remote.php/dav/files, use it directly
    if String.starts_with?(path, "/remote.php/") do
      path
    else
      build_webdav_path(conn, path)
    end
  end

  defp relative_path(%__MODULE__{username: username}, href) do
    prefix = "/remote.php/dav/files/" <> encode_component(username)
    String.trim_leading(href, prefix)
  end

  defp item_path(%{id: id}), do: id
  defp item_path(%{"id" => id}), do: id

  defp normalize_href(nil), do: ""

  defp normalize_href(href) do
    href
    |> URI.decode()
    |> String.trim_trailing("/")
  end

  defp encode_component(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp encode_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &encode_component/1)
  end

  # --- XML Parsing ---
  # Regex-based parsing for WebDAV multistatus responses.
  # Handles common namespace prefixes (d:, D:, and unprefixed DAV elements).

  defp parse_multistatus(body) when is_binary(body) do
    # Match response blocks with any namespace prefix or none
    ~r/<(?:\w+:)?response\b[^>]*>(.*?)<\/(?:\w+:)?response>/s
    |> Regex.scan(body, capture: :first)
    |> Enum.map(fn [block] -> parse_response_block(block) end)
  end

  defp parse_multistatus(_), do: []

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

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(date_string) when is_binary(date_string) do
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
            Logger.warning(
              "Nextcloud: unparseable date #{inspect(date_string)}, using current time"
            )

            DateTime.utc_now()
        end

      _ ->
        Logger.warning("Nextcloud: unparseable date #{inspect(date_string)}, using current time")
        DateTime.utc_now()
    end
  end
end
