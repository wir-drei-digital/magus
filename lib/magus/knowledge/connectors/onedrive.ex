defmodule Magus.Knowledge.Connectors.Onedrive do
  @moduledoc """
  Knowledge connector for Microsoft OneDrive via the Microsoft Graph API.

  Uses Graph's driveItem endpoints to list folders, list files within a folder,
  fetch file content, and detect changes via the per-folder `delta` feed.

  ## Auth Config

      %{"access_token" => "EwB…", "refresh_token" => "M.C5…"}

  Obtain tokens via OAuth2 against the Microsoft identity platform with the
  `Files.Read.All offline_access` scopes. Token refresh (including Microsoft's
  refresh-token rotation) is handled proactively by `Magus.Knowledge.TokenManager`
  through `Magus.Knowledge.OAuth.refresh_token/2` before each sync job, so this
  connector only carries a short-lived `Bearer` access token.

  ## Delta semantics

  Graph's `delta` feed returns absolute `@odata.nextLink` (pagination) and
  `@odata.deltaLink` (the cursor for the next incremental run) URLs. These are
  followed verbatim, never re-prefixed with the base URL. A `410 Gone`
  (`resyncRequired`) means the stored deltaLink expired; the connector returns
  `{:error, :cursor_reset}` so the sync framework can clear the cursor and fall
  back to a full listing (whose diff catches deletions missed during the gap).

  ## Features

  - Recursive subfolder listing
  - `cTag`-based change detection (cTag changes only on content change)
  - Delta feed emits `:deleted` changes, so the framework skips deletion
    reconciliation (`deletes_in_delta?/0 == true`)
  - 100MB download size limit, 300s content timeout
  """

  @behaviour Magus.Knowledge.Connector

  require Logger

  @default_base_url "https://graph.microsoft.com/v1.0"
  @max_download_size 100 * 1024 * 1024
  @content_download_timeout 300_000

  defp base_url, do: Application.get_env(:magus, :onedrive_api_base_url, @default_base_url)

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
    url =
      case path do
        nil -> base_url() <> "/me/drive/root/children"
        folder_id -> base_url() <> "/me/drive/items/#{folder_id}/children"
      end

    with {:ok, entries} <- drain_pages(conn, url, []) do
      folders =
        entries
        |> Enum.filter(&folder?/1)
        |> Enum.map(fn item ->
          %{id: item["id"], name: item["name"], path: "/" <> item["id"]}
        end)

      {:ok, folders}
    end
  end

  @impl true
  def list_items(%__MODULE__{} = conn, collection, _cursor) do
    folder_id = collection_id(collection)
    list_items_recursive(conn, [folder_id], MapSet.new(), [])
  end

  @impl true
  def fetch_content(%__MODULE__{} = conn, item) do
    item_id = item_id(item)
    url = base_url() <> "/me/drive/items/#{item_id}/content"

    # Graph 302-redirects the content endpoint to a pre-signed download URL;
    # Req follows redirects by default.
    case get_binary(conn, url) do
      {:ok, body} ->
        {:ok, body, %{"item_id" => item_id, "format" => "binary"}}

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
        # Bootstrap: enumerate the whole folder to obtain a starting deltaLink,
        # discarding the items (the full sync owns initial creation).
        folder_id = collection_id(collection)
        url = base_url() <> "/me/drive/items/#{folder_id}/delta"

        case drain_delta(conn, url, []) do
          {:ok, _entries, delta_link} ->
            {:ok, [], %{"sync_cursor" => delta_link}}

          {:error, reason} ->
            {:error, reason}
        end

      delta_link ->
        # Incremental: GET the stored deltaLink verbatim.
        case drain_delta(conn, delta_link, []) do
          {:ok, entries, new_delta_link} ->
            changes =
              entries
              |> Enum.map(&entry_to_change/1)
              |> Enum.reject(&is_nil/1)

            {:ok, changes, %{"sync_cursor" => new_delta_link}}

          {:error, reason} ->
            {:error, reason}
        end
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

  # --- Private: children pagination (absolute nextLink) ---

  defp drain_pages(conn, url, acc) do
    case get_json(conn, url) do
      {:ok, %{"value" => value} = body} ->
        new_acc = [value | acc]

        case body["@odata.nextLink"] do
          nil -> {:ok, new_acc |> Enum.reverse() |> List.flatten()}
          next_link -> drain_pages(conn, next_link, new_acc)
        end

      {:ok, _body} ->
        {:ok, acc |> Enum.reverse() |> List.flatten()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: recursive file listing ---

  defp list_items_recursive(_conn, [], _seen, acc) do
    {:ok, acc |> Enum.reverse() |> List.flatten(), nil}
  end

  defp list_items_recursive(conn, [folder_id | rest], seen, acc) do
    if MapSet.member?(seen, folder_id) do
      list_items_recursive(conn, rest, seen, acc)
    else
      seen = MapSet.put(seen, folder_id)
      url = base_url() <> "/me/drive/items/#{folder_id}/children"

      case drain_pages(conn, url, []) do
        {:ok, entries} ->
          {folders, files} = Enum.split_with(entries, &folder?/1)
          child_ids = Enum.map(folders, & &1["id"])
          items = Enum.map(files, &item_from_entry/1)
          list_items_recursive(conn, child_ids ++ rest, seen, [items | acc])

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --- Private: delta feed (absolute nextLink/deltaLink) ---

  defp drain_delta(conn, url, acc) do
    case get_json(conn, url) do
      {:ok, %{"value" => value} = body} ->
        new_acc = [value | acc]

        cond do
          body["@odata.nextLink"] ->
            drain_delta(conn, body["@odata.nextLink"], new_acc)

          body["@odata.deltaLink"] ->
            {:ok, new_acc |> Enum.reverse() |> List.flatten(), body["@odata.deltaLink"]}

          true ->
            {:ok, new_acc |> Enum.reverse() |> List.flatten(), url}
        end

      {:error, {:graph_api_error, 410, _body}} ->
        {:error, :cursor_reset}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp entry_to_change(entry) do
    cond do
      Map.has_key?(entry, "deleted") ->
        %{type: :deleted, item: %{id: entry["id"]}}

      folder?(entry) ->
        nil

      true ->
        %{type: :updated, item: item_from_entry(entry)}
    end
  end

  # --- Private: HTTP ---

  defp get_json(%__MODULE__{access_token: token}, url) do
    case Req.get(url,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: 30_000,
           max_retries: 0
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("OneDrive Graph API error: status=#{status} body=#{inspect(body)}")
        {:error, {:graph_api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp get_binary(%__MODULE__{access_token: token}, url) do
    case Req.get(url,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: @content_download_timeout,
           redirect: true,
           max_retries: 0
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if byte_size(body) > @max_download_size do
          {:error, :file_too_large}
        else
          {:ok, body}
        end

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("OneDrive Graph content error: status=#{status} body=#{inspect(body)}")
        {:error, {:graph_api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  # --- Private: helpers ---

  defp folder?(entry), do: Map.has_key?(entry, "folder")

  defp item_from_entry(entry) do
    %{
      id: entry["id"],
      name: entry["name"],
      etag: entry["cTag"] || entry["eTag"],
      updated_at: parse_datetime(entry["lastModifiedDateTime"]),
      mime_type: get_in(entry, ["file", "mimeType"]) || "application/octet-stream"
    }
  end

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
