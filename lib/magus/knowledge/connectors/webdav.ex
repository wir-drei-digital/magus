defmodule Magus.Knowledge.Connectors.Webdav do
  @moduledoc """
  Generic WebDAV knowledge connector.

  A thin adapter over `Magus.Knowledge.Connectors.Webdav.Client` for any
  standards-compliant WebDAV server where the configured `base_url` is already
  the DAV collection root. Unlike the Nextcloud connector there is no
  path-prefix magic: PROPFIND/GET requests hit `base_url <> path` directly and
  hrefs are used verbatim.

  Suitable for providers that expose a plain WebDAV endpoint, including:

    * ownCloud
    * Koofr
    * Hetzner Storage Share
    * Fastmail Files
    * kDrive paid tiers

  Uses recursive `Depth: 1` PROPFIND requests instead of `Depth: infinity`
  for compatibility. Handles 429/503 rate limiting with automatic retry using
  the `Retry-After` header.

  ## Auth Config

      %{"base_url" => "https://dav.example.com/remote/dav", "username" => "user", "password" => "pass"}

  `base_url` IS the DAV collection root. `username`/`password` are sent as HTTP
  Basic auth; the password can be an app-specific password where the provider
  supports one.
  """

  @behaviour Magus.Knowledge.Connector

  alias Magus.Knowledge.Connectors.Webdav.Client

  require Logger

  @max_depth 10

  defstruct [:base_url, :username, :password]

  # --- Connector callbacks ---

  @impl true
  def connect(%{"base_url" => base_url, "username" => username, "password" => password} = _config)
      when is_binary(base_url) and base_url != "" and
             is_binary(username) and username != "" and
             is_binary(password) and password != "" do
    # Normalize base_url — strip trailing slash so it is a clean DAV root.
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
    webdav_path = build_path(path || "/")

    case propfind(conn, webdav_path, 1) do
      {:ok, body} ->
        folders =
          body
          |> Client.parse_multistatus()
          |> Enum.filter(
            &(&1.is_collection &&
                Client.normalize_href(&1.href) != Client.normalize_href(webdav_path))
          )
          |> Enum.map(fn entry ->
            %{
              id: entry.href,
              name: entry.display_name || Path.basename(URI.decode(entry.href)),
              path: relative_path(entry.href)
            }
          end)

        {:ok, folders}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_items(%__MODULE__{} = conn, collection, _cursor) do
    webdav_path = collection_path(collection)

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
              updated_at: Client.parse_datetime(entry.last_modified),
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
        entries = Client.parse_multistatus(body)

        # Separate files from subdirectories (exclude self)
        normalized_self = Client.normalize_href(webdav_path)

        {subdirs, files} =
          entries
          |> Enum.reject(&(Client.normalize_href(&1.href) == normalized_self))
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

    case Client.request_with_retry(:get, url, auth_headers(conn)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        metadata = %{"path" => path, "format" => "raw"}
        {:ok, body, metadata}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("WebDAV GET error: status=#{status} path=#{path}")
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
    Client.propfind(conn.base_url, auth_headers(conn), path, depth)
  end

  defp auth_headers(%__MODULE__{username: username, password: password}) do
    Client.basic_auth_headers(username, password)
  end

  # base_url IS the DAV root, so there is no prefix: paths map straight onto it.
  # Encode each segment and normalize to a trailing-slash collection path.
  defp build_path(path) do
    path = String.trim_leading(path, "/")

    if path == "" do
      "/"
    else
      "/" <> Client.encode_path(path) <> "/"
    end
  end

  defp collection_path(collection) do
    path =
      case collection do
        %{path: p} when is_binary(p) -> p
        %{"path" => p} when is_binary(p) -> p
        %{external_id: id} when is_binary(id) -> id
        %{"external_id" => id} when is_binary(id) -> id
        _ -> "/"
      end

    # An href captured from a prior PROPFIND is already an absolute, encoded DAV
    # path (starts with "/"); use it verbatim, only ensuring a trailing slash so
    # the server treats it as a collection. A user-supplied logical path gets
    # encoded onto the root.
    cond do
      String.starts_with?(path, "/") -> ensure_trailing_slash(path)
      true -> build_path(path)
    end
  end

  defp ensure_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end

  # base_url is the DAV root and hrefs are absolute paths under it, so the
  # relative path is the href itself (prefix "").
  defp relative_path(href), do: href

  defp item_path(%{id: id}), do: id
  defp item_path(%{"id" => id}), do: id
end
