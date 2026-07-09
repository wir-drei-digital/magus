defmodule Magus.Knowledge.Connectors.Kdrive do
  @moduledoc """
  Knowledge connector for Infomaniak kDrive via the Infomaniak REST API.

  Authenticates with a long-lived Manager API token (`Bearer`), so there is no
  OAuth flow and `Magus.Knowledge.TokenManager` is not involved: the token is
  carried verbatim in every request.

  ## Auth Config

      %{"api_token" => "kd-XXXX"}

  Generate the token in the Infomaniak Manager (API token with `drive` scope).

  ## Identity scheme

  kDrive scopes everything by `drive_id` + `file_id`, so folders and items use a
  composite id `"{drive_id}:{file_id}"`.

  - `list_folders(conn, nil)` lists the accessible DRIVES (`GET /2/drive`); each
    drive maps to a synthetic root folder `%{id: "{drive_id}:root", ...}`.
  - `list_folders(conn, "{drive_id}:{file_id_or_root}")` lists the child
    DIRECTORIES of that file (`GET /3/drive/{drive_id}/files/{file_id}/files`,
    filtered to `type == "dir"`). The literal `:root` alias resolves to file id
    `1` (see @root_file_id).

  ## Change detection

  kDrive exposes an activities feed, but this connector does not use it yet:
  `detect_changes/3` returns `{:error, :not_supported}`, which routes the sync
  framework to the fallback full-listing diff. That diff handles both updates
  (via changed `revised_at` etags) AND deletions (entries that vanish from the
  listing), so no delta/deletion signal is required. The activities feed is a
  documented v2 follow-up.

  ## Rate limiting

  The Infomaniak API allows 60 requests/minute. The recursive listing paces
  itself naturally at current collection sizes, and the app-level RateLimiter
  caps sync frequency; if a large drive still trips a 429, `request_with_retry`
  honors the `Retry-After` header (max 3 retries, capped at 15s so a single
  sleep cannot stall one of the 5 global knowledge_sync queue slots).

  ## Response envelope & timestamps

  Infomaniak wraps payloads as `%{"data" => ...}`. File objects carry a `type`
  discriminator (`"dir"` vs `"file"`) and Unix-epoch-second timestamps
  (`revised_at`, `updated_at`), verified against the official Infomaniak
  Android/iOS kDrive clients (`revisedAtInMillis = revisedAt * 1000`).
  Directory listings paginate with `page`/`per_page`; the connector drains
  pages until one returns fewer than `@page_size` entries.
  """

  @behaviour Magus.Knowledge.Connector

  require Logger

  @default_base_url "https://api.infomaniak.com"

  # Verified against the official Infomaniak iOS client (ios-kDrive,
  # Endpoint+Files.swift `rootFiles`: ".../files/1/files") and Android client
  # (android-kDrive File.kt). The drive root directory has file id 1.
  @root_file_id 1

  @max_depth 10
  @page_size 500
  @max_download_size 100 * 1024 * 1024
  @content_download_timeout 300_000

  defp base_url, do: Application.get_env(:magus, :kdrive_api_base_url, @default_base_url)

  defstruct [:api_token]

  # --- Connector callbacks ---

  @impl true
  def connect(%{"api_token" => api_token}) when is_binary(api_token) and api_token != "" do
    {:ok, %__MODULE__{api_token: api_token}}
  end

  def connect(_auth_config) do
    {:error, :missing_api_token}
  end

  @impl true
  def list_folders(%__MODULE__{} = conn, nil) do
    url = base_url() <> "/2/drive"

    with {:ok, drives} <- drain_pages(conn, url, 1, []) do
      folders =
        Enum.map(drives, fn drive ->
          drive_id = to_string(drive["id"])

          %{
            id: "#{drive_id}:root",
            name: drive["name"],
            path: "/#{drive_id}"
          }
        end)

      {:ok, folders}
    end
  end

  @impl true
  def list_folders(%__MODULE__{} = conn, composite_id) when is_binary(composite_id) do
    {drive_id, file_id} = parse_composite(composite_id)
    url = files_url(drive_id, file_id)

    with {:ok, entries} <- drain_pages(conn, url, 1, []) do
      folders =
        entries
        |> Enum.filter(&directory?/1)
        |> Enum.map(fn entry ->
          child_id = to_string(entry["id"])

          %{
            id: "#{drive_id}:#{child_id}",
            name: entry["name"],
            path: "/#{drive_id}/#{child_id}"
          }
        end)

      {:ok, folders}
    end
  end

  @impl true
  def list_items(%__MODULE__{} = conn, collection, _cursor) do
    {drive_id, file_id} = parse_composite(collection_id(collection))

    case list_items_recursive(conn, drive_id, file_id, 0) do
      {:ok, items} -> {:ok, items, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def fetch_content(%__MODULE__{} = conn, item) do
    {drive_id, file_id} = parse_composite(item_id(item))
    url = base_url() <> "/2/drive/#{drive_id}/files/#{file_id}/download"

    case request_with_retry(:get_binary, url, conn) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if byte_size(body) > @max_download_size do
          {:error, {:file_too_large, "#{drive_id}:#{file_id}", @max_download_size}}
        else
          metadata = %{"drive_id" => drive_id, "file_id" => file_id, "format" => "binary"}
          {:ok, body, metadata}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("kDrive download error: status=#{status} file=#{drive_id}:#{file_id}")
        {:error, {:kdrive_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  @impl true
  def detect_changes(_conn, _collection, _since) do
    # No delta feed used yet; the fallback full-listing diff handles updates and
    # deletions. The activities feed is a documented v2 follow-up.
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

  # --- Private: recursive file listing ---

  defp list_items_recursive(_conn, _drive_id, _file_id, depth) when depth >= @max_depth,
    do: {:ok, []}

  defp list_items_recursive(conn, drive_id, file_id, depth) do
    url = files_url(drive_id, file_id)

    case drain_pages(conn, url, 1, []) do
      {:ok, entries} ->
        {dirs, files} = Enum.split_with(entries, &directory?/1)

        items = Enum.map(files, &item_from_entry(&1, drive_id))

        child_results =
          Enum.reduce_while(dirs, {:ok, []}, fn dir, {:ok, acc} ->
            case list_items_recursive(conn, drive_id, to_string(dir["id"]), depth + 1) do
              {:ok, children} -> {:cont, {:ok, [children | acc]}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)

        case child_results do
          {:ok, children} -> {:ok, items ++ (children |> Enum.reverse() |> List.flatten())}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: pagination (page/per_page) ---

  defp drain_pages(conn, url, page, acc) do
    paged_url = append_query(url, "per_page=#{@page_size}&page=#{page}")

    case get_json(conn, paged_url) do
      {:ok, %{"data" => data}} when is_list(data) ->
        new_acc = [data | acc]

        if length(data) < @page_size do
          {:ok, new_acc |> Enum.reverse() |> List.flatten()}
        else
          drain_pages(conn, url, page + 1, new_acc)
        end

      {:ok, _body} ->
        {:ok, acc |> Enum.reverse() |> List.flatten()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Private: HTTP ---

  defp get_json(%__MODULE__{} = conn, url) do
    case request_with_retry(:get_json, url, conn) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.warning("kDrive API error: status=#{status} body=#{inspect(body)}")
        {:error, {:kdrive_error, status, body}}

      {:error, reason} ->
        {:error, {:request_failed, reason}}
    end
  end

  defp request_with_retry(kind, url, conn, retries \\ 0) do
    opts =
      case kind do
        :get_json ->
          [
            method: :get,
            url: url,
            headers: auth_headers(conn),
            receive_timeout: 30_000,
            max_retries: 0
          ]

        :get_binary ->
          [
            method: :get,
            url: url,
            headers: auth_headers(conn),
            receive_timeout: @content_download_timeout,
            redirect: true,
            max_retries: 0
          ]
      end

    case Req.request(opts) do
      {:ok, %Req.Response{status: status} = response} when status in [429, 503] and retries < 3 ->
        # Capped at 15s: this sleep occupies one of only 5 global knowledge_sync
        # queue slots, so a large provider-supplied Retry-After should not stall
        # the whole queue.
        retry_after = min(retry_after_seconds(response), 15)

        Logger.warning(
          "kDrive rate limited (#{status}), retrying in #{retry_after}s (attempt #{retries + 1}/3)"
        )

        Process.sleep(retry_after * 1_000)
        request_with_retry(kind, url, conn, retries + 1)

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

  defp auth_headers(%__MODULE__{api_token: token}) do
    [{"authorization", "Bearer #{token}"}]
  end

  # --- Private: helpers ---

  defp files_url(drive_id, file_id) do
    base_url() <> "/3/drive/#{drive_id}/files/#{file_id}/files"
  end

  defp append_query(url, query) do
    separator = if String.contains?(url, "?"), do: "&", else: "?"
    url <> separator <> query
  end

  defp directory?(entry), do: entry["type"] == "dir"

  defp item_from_entry(entry, drive_id) do
    timestamp = entry["revised_at"] || entry["updated_at"]

    %{
      id: "#{drive_id}:#{entry["id"]}",
      name: entry["name"],
      etag: to_string(timestamp),
      updated_at: parse_timestamp(timestamp),
      mime_type: entry["mime_type"] || "application/octet-stream"
    }
  end

  # Composite id "{drive_id}:{file_id}", where file_id may be the literal
  # "root" alias resolving to @root_file_id.
  defp parse_composite(composite_id) when is_binary(composite_id) do
    case String.split(composite_id, ":", parts: 2) do
      [drive_id, "root"] -> {drive_id, to_string(@root_file_id)}
      [drive_id, file_id] -> {drive_id, file_id}
      [drive_id] -> {drive_id, to_string(@root_file_id)}
    end
  end

  defp collection_id(%{external_id: id}) when is_binary(id), do: id
  defp collection_id(%{"external_id" => id}) when is_binary(id), do: id
  defp collection_id(%{id: id}) when is_binary(id), do: id
  defp collection_id(%{"id" => id}) when is_binary(id), do: id

  defp item_id(%{id: id}) when is_binary(id), do: id
  defp item_id(%{"id" => id}) when is_binary(id), do: id

  defp parse_timestamp(nil), do: DateTime.utc_now()

  defp parse_timestamp(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, dt} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp parse_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, _} -> parse_timestamp(seconds)
      :error -> DateTime.utc_now()
    end
  end
end
