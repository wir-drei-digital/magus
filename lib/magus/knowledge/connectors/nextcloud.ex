defmodule Magus.Knowledge.Connectors.Nextcloud do
  @moduledoc """
  Knowledge connector for Nextcloud via WebDAV.

  Thin adapter over `Magus.Knowledge.Connectors.Webdav.Client`. Keeps only the
  Nextcloud-specific pieces: the auth-config shape, the
  `/remote.php/dav/files/{username}` DAV path prefix, and `relative_path/2`.
  All generic WebDAV mechanics (PROPFIND/GET, retry, XML/date parsing) live in
  the shared client.

  Uses recursive `Depth: 1` PROPFIND requests instead of `Depth: infinity`
  for compatibility — many Nextcloud instances disable infinite depth.

  Handles 429/503 rate limiting with automatic retry using the `Retry-After`
  header.

  ## Auth Config

      %{"base_url" => "https://cloud.example.com", "username" => "user", "password" => "pass"}

  The password can be an app-specific password generated in Nextcloud settings.
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
    # Normalize base_url — strip trailing slash
    base_url = String.trim_trailing(base_url, "/")

    case Magus.Knowledge.TransportPolicy.validate_base_url(base_url) do
      :ok ->
        {:ok,
         %__MODULE__{
           base_url: base_url,
           username: username,
           password: password
         }}

      {:error, reason} ->
        {:error, reason}
    end
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
          |> Client.parse_multistatus()
          |> Enum.filter(
            &(&1.is_collection &&
                Client.normalize_href(&1.href) != Client.normalize_href(webdav_path))
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
    Client.propfind(conn.base_url, auth_headers(conn), path, depth)
  end

  defp auth_headers(%__MODULE__{username: username, password: password}) do
    Client.basic_auth_headers(username, password)
  end

  defp build_webdav_path(%__MODULE__{username: username}, path) do
    base = "/remote.php/dav/files/" <> Client.encode_component(username)
    path = String.trim_leading(path, "/")

    if path == "" do
      base <> "/"
    else
      base <> "/" <> Client.encode_path(path) <> "/"
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
    prefix = "/remote.php/dav/files/" <> Client.encode_component(username)
    String.trim_leading(href, prefix)
  end

  defp item_path(%{id: id}), do: id
  defp item_path(%{"id" => id}), do: id
end
