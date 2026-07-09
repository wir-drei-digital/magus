defmodule Magus.Knowledge.KnowledgeCollection.Changes.SyncHelpers do
  @moduledoc """
  Shared helpers for FullSync and IncrementalSync change modules.
  """

  require Logger

  alias Magus.Files.Storage
  alias Magus.Knowledge.Connectors.GoogleDrive

  @doc """
  Checks the rate limiter for a sync operation on the given source.
  Returns `:ok` or `{:error, :rate_limited}`.
  """
  def check_rate_limit(source) do
    provider_key =
      case source.provider do
        :google_drive -> :google_drive_knowledge
        :notion -> :notion_knowledge
        :nextcloud -> :nextcloud_knowledge
        :affine -> :affine_knowledge
        other -> other
      end

    Magus.Integrations.RateLimiter.check(source.user_id, provider_key, :sync)
  end

  @doc """
  Persists a refreshed OAuth token back to the KnowledgeSource if the
  connector performed a token refresh during this sync job.
  """
  def maybe_persist_refreshed_token(conn, connector, source) do
    if connector == GoogleDrive do
      case GoogleDrive.refreshed_auth_config(conn) do
        nil ->
          :ok

        new_auth_config ->
          # `:update_auth_config` REPLACES the whole attribute, so merge here
          # (mirrors TokenManager.persist/2's proactive-path merge) to keep any
          # keys the reactive refresh didn't touch, such as expires_at.
          merged_auth_config = Map.merge(source.auth_config || %{}, new_auth_config)

          case Magus.Knowledge.update_source_auth_config(
                 source,
                 %{auth_config: merged_auth_config},
                 authorize?: false
               ) do
            {:ok, _} ->
              Logger.info("Persisted refreshed Google Drive token for source #{source.id}")

            {:error, reason} ->
              Logger.warning(
                "Failed to persist refreshed token for source #{source.id}: #{inspect(reason)}"
              )
          end
      end
    end
  end

  @doc """
  Hard-delete a file whose remote counterpart disappeared.

  Sync deletions bypass the user trash on purpose (user decision 2026-07-09):
  the remote is the source of truth for connector files, and soft-deleted
  copies would hold chunks, storage bytes, and quota forever. User-initiated
  deletion still goes through `:soft_delete` and the trash.
  """
  def delete_remote_gone_file(file) do
    case Magus.Files.delete_file(file, authorize?: false) do
      :ok ->
        :ok

      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Sync: failed to hard-delete file #{file.id}: #{inspect(reason)}")
        :error
    end
  end

  @doc """
  Renders a sync failure `reason` as a user-facing `last_error` string.
  """
  def format_sync_error(:reauth_required),
    do: "Authorization expired. Reconnect this source to resume syncing."

  def format_sync_error(:rate_limited),
    do: "Rate limited by the provider. The next scheduled sync will retry automatically."

  def format_sync_error(reason), do: inspect(reason)

  @doc "SHA-256 hex digest used as the stored content fingerprint."
  def content_hash(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @doc """
  Fetch remote content for `item` and update the local `file`.

  Layers, in order:
    1. Content-hash guard: when the fetched bytes hash to the stored
       `metadata["content_hash"]`, only `external_etag`/`last_synced_at` are
       bumped. No re-store, no `:pending`, no new chunks.
    2. Quota: same limits as create. An oversized update keeps the old
       content and surfaces `{:error, {:quota_exceeded, msg}}` as an item error.

  Returns `{:ok, :updated}`, `{:ok, :unchanged}`, or `{:error, reason}`.
  """
  def update_existing_file(conn, connector, file, item, actor) do
    case apply(connector, :fetch_content, [conn, item]) do
      {:ok, content, metadata} ->
        hash = content_hash(content)

        if hash == (file.metadata || %{})["content_hash"] do
          touch_unchanged_file(file, item)
        else
          store_updated_file(file, item, content, metadata, hash, actor)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp touch_unchanged_file(file, item) do
    case Magus.Files.update_file_from_connector(
           file,
           %{external_etag: item.etag, last_synced_at: DateTime.utc_now()},
           authorize?: false
         ) do
      {:ok, _} -> {:ok, :unchanged}
      {:error, reason} -> {:error, reason}
    end
  end

  defp store_updated_file(file, item, content, metadata, hash, actor) do
    effective_mime = Map.get(metadata || %{}, "export_mime", item.mime_type)
    file_size = byte_size(content)

    with :ok <- check_update_quota(actor, file_size),
         storage_path =
           file.file_path || Storage.generate_path(file.user_id, file.id, item.name),
         {:ok, _} <- store_content(storage_path, content),
         {:ok, _updated} <-
           Magus.Files.update_file_from_connector(
             file,
             %{
               external_etag: item.etag,
               external_updated_at: item.updated_at,
               last_synced_at: DateTime.utc_now(),
               status: :pending,
               file_path: storage_path,
               file_size: file_size,
               mime_type: effective_mime,
               metadata: Map.put(file.metadata || %{}, "content_hash", hash)
             },
             authorize?: false
           ) do
      {:ok, :updated}
    end
  end

  defp check_update_quota(actor, file_size) do
    case Magus.Usage.PolicyEnforcer.check_file_upload(actor, file_size) do
      {:ok, :allowed} ->
        :ok

      {:error, error} ->
        {:error, {:quota_exceeded, Magus.Usage.PolicyErrorMessage.message(error)}}
    end
  end

  defp store_content(path, content) do
    case Storage.store(path, content) do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, {:storage_failed, reason}}
    end
  end
end
