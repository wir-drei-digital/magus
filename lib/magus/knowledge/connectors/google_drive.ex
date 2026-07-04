defmodule Magus.Knowledge.Connectors.GoogleDrive do
  @moduledoc """
  Knowledge connector for Google Drive.

  Uses the Google Drive API v3 to list folders, query files within folders,
  fetch file content, and detect changes via the Changes API.

  ## Auth Config

      %{"access_token" => "ya29.…", "refresh_token" => "1//…"}

  Obtain tokens via OAuth2 with the `drive.readonly` scope.

  ## Features

  - Automatic OAuth token refresh on 401 responses
  - Recursive subfolder sync
  - Paginated folder listing with parent filtering
  - Google Workspace document export (Docs → Markdown, Sheets → CSV)
  - 100MB download size limit
  """

  @behaviour Magus.Knowledge.Connector

  require Logger

  @default_base_url "https://www.googleapis.com/drive/v3"
  @max_download_size 100 * 1024 * 1024
  @content_download_timeout 300_000
  @folder_mime_type "application/vnd.google-apps.folder"

  defp base_url, do: Application.get_env(:magus, :google_drive_base_url, @default_base_url)

  defstruct [:access_token, :refresh_token]

  # Google Workspace MIME types that can be exported to downloadable formats.
  # Any `application/vnd.google-apps.*` type not listed here cannot be
  # meaningfully downloaded (Forms, Sites, Maps, Shortcuts, etc.) and will
  # be skipped during sync.
  @google_workspace_export_types %{
    "application/vnd.google-apps.document" => "text/markdown",
    "application/vnd.google-apps.spreadsheet" => "text/csv",
    "application/vnd.google-apps.presentation" => "text/plain",
    "application/vnd.google-apps.drawing" => "image/png"
  }

  @google_workspace_prefix "application/vnd.google-apps."

  # --- Connector callbacks ---

  @impl true
  def connect(%{"access_token" => access_token} = config)
      when is_binary(access_token) and access_token != "" do
    {:ok,
     %__MODULE__{
       access_token: access_token,
       refresh_token: Map.get(config, "refresh_token")
     }}
  end

  def connect(_auth_config) do
    {:error, :missing_access_token}
  end

  @impl true
  def list_folders(%__MODULE__{} = conn, path) do
    do_list_folders(conn, path, nil, [])
  end

  @impl true
  def list_items(%__MODULE__{} = conn, collection, cursor) do
    folder_id = collection_id(collection)

    # On first call, discover all subfolder IDs recursively
    {folders, page_token} =
      case cursor do
        nil ->
          all_folder_ids = discover_all_folder_ids(conn, folder_id)
          {[folder_id | all_folder_ids], nil}

        %{"folders" => folders, "pageToken" => pt} ->
          {folders, pt}

        %{"folders" => folders} ->
          {folders, nil}
      end

    list_items_from_folders(conn, folders, page_token)
  end

  @impl true
  def fetch_content(%__MODULE__{} = conn, item) do
    file_id = item_id(item)
    mime_type = item_mime_type(item)

    cond do
      export_mime = Map.get(@google_workspace_export_types, mime_type) ->
        # Google Workspace file with known export format
        fetch_export(conn, file_id, export_mime)

      String.starts_with?(mime_type, @google_workspace_prefix) ->
        # Google Workspace file without a known export format (Forms, Sites, etc.)
        # These cannot be downloaded via alt=media or exported meaningfully.
        Logger.info("Skipping non-exportable Google Workspace file #{file_id} (#{mime_type})")
        {:error, {:not_exportable, mime_type}}

      true ->
        # Binary file — download directly
        fetch_binary(conn, file_id)
    end
  end

  @impl true
  def detect_changes(%__MODULE__{} = conn, collection, _since) do
    # The Drive Changes API uses a page token (sync_cursor), not a timestamp.
    page_token = get_sync_cursor(collection)

    case page_token do
      nil ->
        # No cursor yet — caller should do a full sync first.
        # Get a start page token for future incremental syncs.
        case get(conn, "/changes/startPageToken", []) do
          {:ok, %{"startPageToken" => token}} ->
            {:ok, [], %{"sync_cursor" => token}}

          {:error, reason} ->
            {:error, reason}
        end

      token ->
        folder_id = collection_id(collection)
        all_folder_ids = MapSet.new([folder_id | discover_all_folder_ids(conn, folder_id)])
        fetch_changes(conn, token, all_folder_ids)
    end
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

  @doc """
  Returns updated auth config if the access token was refreshed during this
  sync job. Returns `nil` if no refresh occurred.

  Call this after sync completes to persist the refreshed token.
  """
  def refreshed_auth_config(%__MODULE__{refresh_token: rt}) when is_binary(rt) do
    case Process.get({:gdrive_refreshed_token, rt}) do
      nil ->
        nil

      new_access_token ->
        # Use rotated refresh token if Google issued one, otherwise keep original
        effective_refresh = Process.get({:gdrive_refreshed_refresh_token, rt}) || rt

        %{
          "access_token" => new_access_token,
          "refresh_token" => effective_refresh
        }
    end
  end

  def refreshed_auth_config(_conn), do: nil

  # --- Private: folder listing with parent filter + pagination ---

  defp do_list_folders(conn, parent_id, page_token, acc) do
    q =
      if parent_id do
        "mimeType='#{@folder_mime_type}' and '#{parent_id}' in parents and trashed=false"
      else
        "mimeType='#{@folder_mime_type}' and 'root' in parents and trashed=false"
      end

    params =
      [q: q, fields: "nextPageToken,files(id,name,parents)", pageSize: 100] ++
        if(page_token, do: [pageToken: page_token], else: [])

    case get(conn, "/files", params) do
      {:ok, %{"files" => files} = response} ->
        folders =
          Enum.map(files, fn file ->
            %{
              id: file["id"],
              name: file["name"],
              path: "/#{file["id"]}"
            }
          end)

        new_acc = [folders | acc]

        case response["nextPageToken"] do
          nil -> {:ok, new_acc |> Enum.reverse() |> List.flatten()}
          next -> do_list_folders(conn, parent_id, next, new_acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: recursive subfolder discovery ---

  defp discover_all_folder_ids(conn, root_folder_id) do
    do_discover_folders(conn, [root_folder_id], MapSet.new(), [])
  end

  defp do_discover_folders(_conn, [], _seen, acc), do: Enum.reverse(acc)

  defp do_discover_folders(conn, [folder_id | rest], seen, acc) do
    if MapSet.member?(seen, folder_id) do
      do_discover_folders(conn, rest, seen, acc)
    else
      seen = MapSet.put(seen, folder_id)

      case list_child_folder_ids(conn, folder_id) do
        {:ok, child_ids} ->
          do_discover_folders(conn, child_ids ++ rest, seen, Enum.reverse(child_ids) ++ acc)

        {:error, reason} ->
          Logger.warning("Failed to list subfolders of #{folder_id}: #{inspect(reason)}")
          do_discover_folders(conn, rest, seen, acc)
      end
    end
  end

  defp list_child_folder_ids(conn, parent_id, page_token \\ nil, acc \\ []) do
    params =
      [
        q: "mimeType='#{@folder_mime_type}' and '#{parent_id}' in parents and trashed=false",
        fields: "nextPageToken,files(id)",
        pageSize: 100
      ] ++ if(page_token, do: [pageToken: page_token], else: [])

    case get(conn, "/files", params) do
      {:ok, %{"files" => files} = response} ->
        ids = Enum.map(files, & &1["id"])
        new_acc = [ids | acc]

        case response["nextPageToken"] do
          nil -> {:ok, new_acc |> Enum.reverse() |> List.flatten()}
          next -> list_child_folder_ids(conn, parent_id, next, new_acc)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: list items across multiple folders ---

  defp list_items_from_folders(_conn, [], _page_token) do
    {:ok, [], nil}
  end

  defp list_items_from_folders(conn, [current_folder | remaining], page_token) do
    base_params = [
      q:
        "'#{current_folder}' in parents and mimeType != '#{@folder_mime_type}' and trashed=false",
      fields: "nextPageToken,files(id,name,mimeType,modifiedTime,md5Checksum)",
      pageSize: 100
    ]

    params =
      if page_token do
        [{:pageToken, page_token} | base_params]
      else
        base_params
      end

    case get(conn, "/files", params) do
      {:ok, %{"files" => files} = response} ->
        items =
          Enum.map(files, fn file ->
            %{
              id: file["id"],
              name: file["name"],
              etag: file["md5Checksum"] || file["modifiedTime"],
              updated_at: parse_datetime(file["modifiedTime"]),
              mime_type: file["mimeType"] || "application/octet-stream"
            }
          end)

        new_cursor =
          case response["nextPageToken"] do
            nil ->
              # Current folder done, move to next
              if remaining == [] do
                nil
              else
                %{"folders" => remaining}
              end

            token ->
              %{"folders" => [current_folder | remaining], "pageToken" => token}
          end

        {:ok, items, new_cursor}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: content fetching ---

  defp fetch_binary(conn, file_id) do
    case get(conn, "/files/#{file_id}", [alt: "media"],
           max_size: @max_download_size,
           timeout: @content_download_timeout
         ) do
      {:ok, body} ->
        {:ok, body, %{"file_id" => file_id, "format" => "binary"}}

      {:error, :file_too_large} ->
        {:error, {:file_too_large, file_id, @max_download_size}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_export(conn, file_id, export_mime) do
    case get(conn, "/files/#{file_id}/export", [mimeType: export_mime],
           max_size: @max_download_size,
           timeout: @content_download_timeout
         ) do
      {:ok, body} ->
        {:ok, body, %{"file_id" => file_id, "format" => "export", "export_mime" => export_mime}}

      {:error, {:drive_api_error, 403, body}} ->
        Logger.warning(
          "Google Drive export failed for #{file_id} (likely exceeds 10MB export limit): #{inspect(body)}"
        )

        {:error, {:export_too_large, file_id}}

      {:error, :file_too_large} ->
        {:error, {:file_too_large, file_id, @max_download_size}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: changes API ---

  defp fetch_changes(conn, page_token, tracked_folder_ids, acc \\ []) do
    params = [
      pageToken: page_token,
      fields:
        "nextPageToken,newStartPageToken,changes(fileId,removed,file(id,name,mimeType,modifiedTime,md5Checksum,parents))",
      pageSize: 100,
      spaces: "drive",
      includeRemoved: true
    ]

    case get(conn, "/changes", params) do
      {:ok, response} ->
        changes =
          (response["changes"] || [])
          |> Enum.filter(fn change ->
            if change["removed"] do
              # Let removals through — IncrementalSync checks against existing files
              true
            else
              # For non-removed changes, check if file is in any tracked folder
              file = change["file"]
              file && Enum.any?(file["parents"] || [], &MapSet.member?(tracked_folder_ids, &1))
            end
          end)
          |> Enum.map(fn change ->
            if change["removed"] do
              %{type: :deleted, item: %{id: change["fileId"]}}
            else
              file = change["file"]

              %{
                type: :updated,
                item: %{
                  id: file["id"],
                  name: file["name"],
                  etag: file["md5Checksum"] || file["modifiedTime"],
                  updated_at: parse_datetime(file["modifiedTime"]),
                  mime_type: file["mimeType"] || "application/octet-stream"
                }
              }
            end
          end)

        case response["nextPageToken"] do
          nil ->
            final_cursor = response["newStartPageToken"] || page_token
            all_changes = [changes | acc] |> Enum.reverse() |> List.flatten()
            {:ok, all_changes, %{"sync_cursor" => final_cursor}}

          next_token ->
            fetch_changes(conn, next_token, tracked_folder_ids, [changes | acc])
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: HTTP with auto-refresh ---

  defp get(%__MODULE__{refresh_token: refresh_token} = conn, path, params, opts \\ []) do
    token = get_current_token(conn)
    url = base_url() <> path
    max_size = Keyword.get(opts, :max_size)
    timeout = Keyword.get(opts, :timeout, 30_000)

    case do_get(url, token, params, max_size, timeout) do
      {:error, {:drive_api_error, 401, _}} when is_binary(refresh_token) ->
        case Magus.Knowledge.OAuth.refresh_google_token(refresh_token) do
          {:ok, %{"access_token" => new_token, "refresh_token" => new_refresh}} ->
            cache_refreshed_token(refresh_token, new_token, new_refresh)
            do_get(url, new_token, params, max_size, timeout)

          {:error, :reauth_required} ->
            {:error, :reauth_required}

          {:error, reason} ->
            Logger.error("Google Drive token refresh failed: #{inspect(reason)}")
            {:error, :token_refresh_failed}
        end

      result ->
        result
    end
  end

  defp do_get(url, token, params, max_size, timeout) do
    case Req.get(url,
           params: params,
           headers: [{"authorization", "Bearer #{token}"}],
           receive_timeout: timeout,
           max_retries: 0
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        if max_size && is_binary(body) && byte_size(body) > max_size do
          {:error, :file_too_large}
        else
          {:ok, body}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("Google Drive API error: status=#{status} body=#{inspect(body)}")
        {:error, {:drive_api_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp get_current_token(%__MODULE__{access_token: token, refresh_token: rt})
       when is_binary(rt) do
    Process.get({:gdrive_refreshed_token, rt}) || token
  end

  defp get_current_token(%__MODULE__{access_token: token}), do: token

  defp cache_refreshed_token(refresh_token, new_access_token, new_refresh_token) do
    Process.put({:gdrive_refreshed_token, refresh_token}, new_access_token)

    if new_refresh_token do
      Process.put({:gdrive_refreshed_refresh_token, refresh_token}, new_refresh_token)
    end
  end

  # --- Private: helpers ---

  defp collection_id(%{external_id: id}), do: id
  defp collection_id(%{"external_id" => id}), do: id
  defp collection_id(%{id: id}), do: id
  defp collection_id(%{"id" => id}), do: id

  defp item_id(%{id: id}), do: id
  defp item_id(%{"id" => id}), do: id

  defp item_mime_type(%{mime_type: mt}), do: mt
  defp item_mime_type(%{"mime_type" => mt}), do: mt
  defp item_mime_type(_), do: "application/octet-stream"

  defp get_sync_cursor(%{sync_cursor: %{"sync_cursor" => cursor}}) when is_binary(cursor),
    do: cursor

  defp get_sync_cursor(%{"sync_cursor" => %{"sync_cursor" => cursor}}) when is_binary(cursor),
    do: cursor

  # Legacy string format
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
