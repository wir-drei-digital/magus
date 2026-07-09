defmodule Magus.Knowledge.Connectors.Dropbox do
  @moduledoc """
  Knowledge connector for Dropbox via the Dropbox HTTP API v2.

  Lists folders, lists files within a folder, fetches file content, and detects
  changes via Dropbox's `list_folder/continue` cursor delta.

  ## Auth Config

      %{"access_token" => "sl.…"}

  Obtain tokens via OAuth2 with `token_access_type=offline` so the framework can
  refresh. Token refresh is handled proactively by `Magus.Knowledge.TokenManager`
  through `Magus.Knowledge.OAuth.refresh_token/2` before each sync job, so this
  connector only carries a short-lived `Bearer` access token.

  ## Two base URLs

  Dropbox splits RPC and content traffic across two hosts, both configurable:

  - `:dropbox_api_base_url` (default `https://api.dropboxapi.com`) for the RPC
    endpoints (`list_folder`, `list_folder/continue`, `get_latest_cursor`).
  - `:dropbox_content_base_url` (default `https://content.dropboxapi.com`) for
    the binary download endpoint.

  All RPC endpoints are `POST` with a JSON body and a `Bearer` token. The
  download endpoint is `POST` with an empty body and the request arguments in a
  `Dropbox-API-Arg` JSON header; the response body is the raw file bytes.

  ## Identity scheme (design decision)

  Item identity (`item.id`, hence `File.external_id`) is the item's `path_lower`,
  NOT the Dropbox file id. Dropbox's `DeletedMetadata` entries carry only paths
  (no file id), so keying on the file id would break delete correlation. Keying on
  `path_lower` makes create/update/delete line up at the cost of treating a moved
  file as a delete + create (which matches the Drive-connector behavior for moves
  outside tracked folders).

  ## Delta semantics

  `detect_changes/3` uses a Dropbox `list_folder` cursor stored as
  `%{"sync_cursor" => value}`. On bootstrap (nil cursor) the connector calls
  `get_latest_cursor` and returns no changes (the full sync owns initial
  creation). On an incremental run it loops `list_folder/continue` while
  `has_more`, mapping `deleted` entries to `:deleted` (keyed by `path_lower`) and
  `file` entries to `:updated`, skipping `folder` entries. A stale cursor surfaces
  as HTTP 409 with a `reset` error body; the connector returns
  `{:error, :cursor_reset}` so the sync framework can clear the cursor and fall
  back to a full listing.

  ## Features

  - Recursive subfolder listing (`recursive: true`)
  - `content_hash`-based change detection (also powers the downstream hash guard)
  - Delta feed emits `:deleted` changes (`deletes_in_delta?/0 == true`)
  - 100MB download size limit, 300s content timeout
  """

  @behaviour Magus.Knowledge.Connector

  require Logger

  @default_api_base_url "https://api.dropboxapi.com"
  @default_content_base_url "https://content.dropboxapi.com"
  @max_download_size 100 * 1024 * 1024
  @content_download_timeout 300_000

  defp api_base_url,
    do: Application.get_env(:magus, :dropbox_api_base_url, @default_api_base_url)

  defp content_base_url,
    do: Application.get_env(:magus, :dropbox_content_base_url, @default_content_base_url)

  defstruct [:access_token]

  # --- Connector callbacks ---

  @impl true
  def connect(%{"access_token" => access_token})
      when is_binary(access_token) and access_token != "" do
    {:ok, %__MODULE__{access_token: access_token}}
  end

  def connect(_auth_config) do
    {:error, :missing_access_token}
  end

  @impl true
  def list_folders(%__MODULE__{} = conn, path) do
    body = %{path: path || "", recursive: false}

    with {:ok, entries} <- drain_list_folder(conn, "/2/files/list_folder", body, []) do
      folders =
        entries
        |> Enum.filter(&folder?/1)
        |> Enum.map(fn e ->
          %{id: e["path_lower"], name: e["name"], path: e["path_display"]}
        end)

      {:ok, folders}
    end
  end

  @impl true
  def list_items(%__MODULE__{} = conn, collection, _cursor) do
    body = %{path: collection_path(collection), recursive: true}

    with {:ok, entries} <- drain_list_folder(conn, "/2/files/list_folder", body, []) do
      items =
        entries
        |> Enum.filter(&file?/1)
        |> Enum.map(&item_from_entry/1)

      {:ok, items, nil}
    end
  end

  @impl true
  def fetch_content(%__MODULE__{} = conn, item) do
    item_id = item_id(item)

    case download(conn, item_id) do
      {:ok, body} ->
        {:ok, body, %{"path" => item_id, "format" => "binary"}}

      {:error, :file_too_large} ->
        {:error, {:file_too_large, item_id, @max_download_size}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def detect_changes(%__MODULE__{} = conn, collection, _since) do
    case get_sync_cursor(collection) do
      nil ->
        # Bootstrap: obtain a starting cursor; the full sync owns initial creation.
        body = %{path: collection_path(collection), recursive: true}

        case post_json(conn, "/2/files/list_folder/get_latest_cursor", body) do
          {:ok, %{"cursor" => cursor}} ->
            {:ok, [], %{"sync_cursor" => cursor}}

          {:error, reason} ->
            {:error, reason}
        end

      cursor ->
        drain_delta(conn, cursor, [])
    end
  end

  @impl true
  def deletes_in_delta?, do: true

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

  # --- Private: list_folder pagination (has_more + continue) ---

  defp drain_list_folder(conn, path, body, acc) do
    case post_json(conn, path, body) do
      {:ok, %{"entries" => entries} = response} ->
        new_acc = [entries | acc]

        if response["has_more"] do
          drain_list_folder(
            conn,
            "/2/files/list_folder/continue",
            %{cursor: response["cursor"]},
            new_acc
          )
        else
          {:ok, new_acc |> Enum.reverse() |> List.flatten()}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: delta feed (continue loop) ---

  defp drain_delta(conn, cursor, acc) do
    case post_json(conn, "/2/files/list_folder/continue", %{cursor: cursor}) do
      {:ok, %{"entries" => entries} = response} ->
        changes =
          entries
          |> Enum.map(&entry_to_change/1)
          |> Enum.reject(&is_nil/1)

        new_acc = [changes | acc]

        if response["has_more"] do
          drain_delta(conn, response["cursor"], new_acc)
        else
          all_changes = new_acc |> Enum.reverse() |> List.flatten()
          {:ok, all_changes, %{"sync_cursor" => response["cursor"]}}
        end

      {:error, {:dropbox_api_error, 409, body}} ->
        if reset_error?(body) do
          {:error, :cursor_reset}
        else
          {:error, {:dropbox_api_error, 409, body}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Dropbox encodes an expired cursor as HTTP 409 whose error tag or summary is
  # a "reset" error. Match defensively on either the tag or the summary prefix.
  defp reset_error?(%{"error" => %{".tag" => "reset"}}), do: true

  defp reset_error?(%{"error_summary" => summary}) when is_binary(summary),
    do: String.starts_with?(summary, "reset")

  defp reset_error?(_), do: false

  defp entry_to_change(entry) do
    case entry[".tag"] do
      "deleted" -> %{type: :deleted, item: %{id: entry["path_lower"]}}
      "file" -> %{type: :updated, item: item_from_entry(entry)}
      _ -> nil
    end
  end

  # --- Private: HTTP ---

  defp post_json(%__MODULE__{access_token: token}, path, body) do
    url = api_base_url() <> path

    case Req.post(url,
           json: body,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: 30_000,
           max_retries: 0
         ) do
      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        Logger.warning("Dropbox API error: status=#{status} body=#{inspect(response_body)}")
        {:error, {:dropbox_api_error, status, response_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp download(%__MODULE__{access_token: token}, path) do
    url = content_base_url() <> "/2/files/download"

    case Req.post(url,
           body: "",
           headers: [
             {"authorization", "Bearer #{token}"},
             {"dropbox-api-arg", Jason.encode!(%{path: path})}
           ],
           receive_timeout: @content_download_timeout,
           max_retries: 0
         ) do
      {:ok, %Req.Response{status: 200, body: response_body}} when is_binary(response_body) ->
        if byte_size(response_body) > @max_download_size do
          {:error, :file_too_large}
        else
          {:ok, response_body}
        end

      {:ok, %Req.Response{status: 200, body: response_body}} ->
        {:ok, response_body}

      {:ok, %Req.Response{status: status, body: response_body}} ->
        Logger.warning(
          "Dropbox content download error: status=#{status} body=#{inspect(response_body)}"
        )

        {:error, {:dropbox_api_error, status, response_body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # --- Private: helpers ---

  defp folder?(entry), do: entry[".tag"] == "folder"
  defp file?(entry), do: entry[".tag"] == "file"

  defp item_from_entry(entry) do
    %{
      id: entry["path_lower"],
      name: entry["name"],
      etag: entry["content_hash"],
      updated_at: parse_datetime(entry["server_modified"]),
      mime_type: "application/octet-stream"
    }
  end

  # collection_path prefers the collection's external_path (folder path) when a
  # non-empty binary, else external_id. Dropbox root is "" not "/".
  defp collection_path(collection) do
    collection
    |> collection_external_path()
    |> case do
      value when is_binary(value) and value != "" -> value
      _ -> collection_id(collection)
    end
    |> normalize_root()
  end

  defp normalize_root("/"), do: ""
  defp normalize_root(path), do: path

  defp collection_external_path(%{external_path: path}), do: path
  defp collection_external_path(%{"external_path" => path}), do: path
  defp collection_external_path(_), do: nil

  defp collection_id(%{external_id: id}), do: id
  defp collection_id(%{"external_id" => id}), do: id
  defp collection_id(%{id: id}), do: id
  defp collection_id(%{"id" => id}), do: id

  defp item_id(%{id: id}), do: id
  defp item_id(%{"id" => id}), do: id

  defp get_sync_cursor(%{sync_cursor: %{"sync_cursor" => cursor}}) when is_binary(cursor),
    do: cursor

  defp get_sync_cursor(%{"sync_cursor" => %{"sync_cursor" => cursor}}) when is_binary(cursor),
    do: cursor

  defp get_sync_cursor(%{sync_cursor: cursor}) when is_binary(cursor), do: cursor
  defp get_sync_cursor(%{"sync_cursor" => cursor}) when is_binary(cursor), do: cursor
  defp get_sync_cursor(_), do: nil

  defp parse_datetime(nil), do: DateTime.utc_now()

  defp parse_datetime(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end
end
