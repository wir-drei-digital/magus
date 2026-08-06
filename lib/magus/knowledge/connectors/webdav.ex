defmodule Magus.Knowledge.Connectors.Webdav do
  @moduledoc """
  Generic WebDAV knowledge connector.

  A thin adapter over `Magus.Knowledge.Connectors.Webdav.Client` for any
  standards-compliant WebDAV server. The configured `base_url` is the DAV
  collection root and may carry a path component (the common case:
  ownCloud's `/remote.php/dav/files/{user}`, Koofr's `/dav/Koofr`, Hetzner
  Storage Share's `/remote.php/webdav`). PROPFIND `href`s are SERVER-absolute
  per RFC 4918 (they include that path component, and may even be absolute
  URIs), so the connector splits `base_url` into origin + root path at
  connect time: requests go to `origin <> server_path`, and logical paths are
  resolved against the root path.

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

  defstruct [:origin, :root_path, :username, :password]

  # --- Connector callbacks ---

  @impl true
  def connect(%{"base_url" => base_url, "username" => username, "password" => password} = _config)
      when is_binary(base_url) and base_url != "" and
             is_binary(username) and username != "" and
             is_binary(password) and password != "" do
    with {:ok, origin, root_path} <- parse_base_url(base_url),
         :ok <- Magus.Knowledge.TransportPolicy.validate_base_url(base_url) do
      {:ok,
       %__MODULE__{
         origin: origin,
         root_path: root_path,
         username: username,
         password: password
       }}
    else
      :error -> {:error, :invalid_base_url}
      {:error, reason} -> {:error, reason}
    end
  end

  def connect(_auth_config) do
    {:error, :missing_credentials}
  end

  @impl true
  def list_folders(%__MODULE__{} = conn, path) do
    webdav_path = build_path(conn, path || "/")

    case propfind(conn, webdav_path, 1) do
      {:ok, body} ->
        folders =
          body
          |> Client.parse_multistatus()
          |> Enum.map(&%{&1 | href: href_to_path(conn, &1.href)})
          |> Enum.reject(&is_nil(&1.href))
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

        # WebDAV has no cursor-based pagination; return all items
        {:ok, items, nil}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp list_items_recursive(_conn, _path, depth) when depth >= @max_depth, do: {:ok, []}

  defp list_items_recursive(conn, webdav_path, depth) do
    case propfind(conn, webdav_path, 1) do
      {:ok, body} ->
        entries =
          body
          |> Client.parse_multistatus()
          |> Enum.map(&%{&1 | href: href_to_path(conn, &1.href)})
          |> Enum.reject(&is_nil(&1.href))

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
    url = conn.origin <> path

    case Client.request_with_retry(:get, url, auth_headers(conn)) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        metadata = %{"path" => relative_path(conn, path), "format" => "raw"}
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

  # Split the configured base_url into origin (scheme + host + port) and DAV
  # root path. PROPFIND hrefs are server-absolute, so requests must be issued
  # against the ORIGIN, never against base_url (that would double the path).
  defp parse_base_url(base_url) do
    case URI.parse(String.trim_trailing(base_url, "/")) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        origin = %URI{scheme: scheme, host: host, port: uri.port} |> URI.to_string()
        {:ok, String.trim_trailing(origin, "/"), uri.path || ""}

      _ ->
        :error
    end
  end

  defp propfind(%__MODULE__{} = conn, server_path, depth) do
    Client.propfind(conn.origin, auth_headers(conn), server_path, depth)
  end

  defp auth_headers(%__MODULE__{username: username, password: password}) do
    Client.basic_auth_headers(username, password)
  end

  # Resolve a logical (user-facing) path onto the DAV root as a server-absolute
  # collection path with a trailing slash.
  defp build_path(%__MODULE__{root_path: root}, path) do
    path = String.trim_leading(path, "/")

    if path == "" do
      ensure_trailing_slash(if root == "", do: "/", else: root)
    else
      ensure_trailing_slash(root <> "/" <> Client.encode_path(path))
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

    # An href captured from a prior PROPFIND is already a server-absolute,
    # encoded DAV path (it starts with the root path); use it verbatim, only
    # ensuring a trailing slash so the server treats it as a collection. A
    # user-supplied logical path gets resolved onto the root.
    cond do
      conn.root_path != "" and String.starts_with?(path, conn.root_path) ->
        ensure_trailing_slash(path)

      conn.root_path == "" and String.starts_with?(path, "/") ->
        ensure_trailing_slash(path)

      true ->
        build_path(conn, path)
    end
  end

  defp ensure_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end

  # Normalize a multistatus href to a server-absolute path. RFC 4918 allows
  # absolute URIs; accept those only for the connection's own origin (a
  # cross-origin href is dropped rather than fetched with our credentials).
  defp href_to_path(_conn, nil), do: nil

  defp href_to_path(conn, "http" <> _ = href) do
    case URI.parse(href) do
      %URI{scheme: scheme, host: host} = uri ->
        if conn.origin ==
             String.trim_trailing(
               URI.to_string(%URI{scheme: scheme, host: host, port: uri.port}),
               "/"
             ) do
          uri.path || "/"
        else
          Logger.warning("WebDAV: dropping cross-origin href #{href}")
          nil
        end
    end
  end

  defp href_to_path(_conn, href), do: href

  # Strip the DAV root prefix so collection paths read naturally in the UI.
  defp relative_path(%__MODULE__{root_path: ""}, href), do: href

  defp relative_path(%__MODULE__{root_path: root}, href) do
    case String.replace_prefix(href, root, "") do
      "" -> "/"
      stripped -> stripped
    end
  end

  defp item_path(%{id: id}), do: id
  defp item_path(%{"id" => id}), do: id
end
