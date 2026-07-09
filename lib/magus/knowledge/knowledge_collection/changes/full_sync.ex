defmodule Magus.Knowledge.KnowledgeCollection.Changes.FullSync do
  @moduledoc """
  Ash change that performs a full sync of a KnowledgeCollection.

  Paginates through all items from the remote connector, matching against
  existing files by `external_id`: new items are created, changed items
  (list-time etag differs or is nil) are re-fetched and updated, and local
  files absent from the complete remote listing are hard-deleted. The
  deletion pass only runs after pagination completes without error, so a
  mid-listing failure never mass-deletes based on a partial inventory.
  """

  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias Magus.Files.Storage
  alias Magus.Knowledge.Connector
  alias Magus.Knowledge.KnowledgeCollection.Changes.SyncHelpers
  alias Magus.Knowledge.KnowledgeCollection.Changes.SyncLogger
  alias Magus.Knowledge.TokenManager

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, collection ->
      do_full_sync(collection)
      {:ok, collection}
    end)
  end

  @doc false
  def do_full_sync(collection) do
    collection = Ash.load!(collection, [knowledge_source: []], authorize?: false)
    cid = collection.id
    SyncLogger.info(cid, "Starting full sync")

    case run_full_sync(collection) do
      {:ok, _item_count, error_count, content_updated_at} ->
        now = DateTime.utc_now()

        {:ok, actual_count} =
          Magus.Files.File
          |> Ash.Query.filter(knowledge_collection_id == ^cid and is_nil(deleted_at))
          |> Ash.count(authorize?: false)

        SyncLogger.info(cid, "Full sync complete: #{actual_count} files, #{error_count} errors")

        Magus.Knowledge.update_sync_status(
          collection,
          %{
            sync_status: :synced,
            last_synced_at: now,
            content_updated_at: content_updated_at,
            item_count: actual_count,
            error_count: error_count,
            last_error: nil
          },
          authorize?: false
        )

      {:error, reason} ->
        Logger.error("FullSync failed for collection #{cid}: #{inspect(reason)}")
        SyncLogger.error(cid, "Full sync failed: #{inspect(reason)}")

        if reason == :reauth_required do
          TokenManager.mark_source_reauth_required(collection.knowledge_source)
        end

        Magus.Knowledge.update_sync_status(
          collection,
          %{
            sync_status: :error,
            last_error: inspect(reason),
            error_count: (collection.error_count || 0) + 1
          },
          authorize?: false
        )
    end
  end

  defp run_full_sync(collection) do
    source = collection.knowledge_source
    cid = collection.id

    case SyncHelpers.check_rate_limit(source) do
      {:error, :rate_limited} ->
        SyncLogger.warn(cid, "Rate limited, skipping sync")
        {:error, :rate_limited}

      :ok ->
        case TokenManager.ensure_fresh(source) do
          {:error, :reauth_required} ->
            {:error, :reauth_required}

          {:ok, source} ->
            case Connector.connector_for(source.provider) do
              {:error, _} = error ->
                SyncLogger.error(cid, "Unsupported provider: #{source.provider}")
                {:error, error}

              connector ->
                SyncLogger.info(cid, "Connecting to #{source.provider}")

                case apply(connector, :connect, [source.auth_config]) do
                  {:ok, conn} ->
                    result = sync_all_items(conn, connector, collection, source)
                    SyncHelpers.maybe_persist_refreshed_token(conn, connector, source)
                    result

                  {:error, reason} ->
                    SyncLogger.error(cid, "Connection failed: #{inspect(reason)}")
                    {:error, reason}
                end
            end
        end
    end
  end

  defp sync_all_items(conn, connector, collection, source) do
    actor = Ash.get!(Magus.Accounts.User, source.user_id, authorize?: false)
    existing = get_existing_files(collection)
    existing_by_external_id = Map.new(existing, &{&1.external_id, &1})

    SyncLogger.info(collection.id, "Found #{map_size(existing_by_external_id)} existing files")

    state = %{
      conn: conn,
      connector: connector,
      collection: collection,
      source: source,
      actor: actor,
      existing_by_external_id: existing_by_external_id
    }

    case do_paginate(state, nil, 0, 0, nil, MapSet.new()) do
      {:ok, total_items, total_errors, updated_max, remote_ids} ->
        delete_remote_gone_files(state, remote_ids)
        {:ok, total_items, total_errors, updated_max}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_paginate(state, cursor, item_count, error_count, max_updated_at, remote_ids) do
    %{conn: conn, connector: connector, collection: collection} = state

    case apply(connector, :list_items, [conn, collection, cursor]) do
      {:ok, items, new_cursor} ->
        SyncLogger.info(collection.id, "Listed #{length(items)} items from provider")

        {new_item_count, new_error_count, new_max_updated_at} =
          process_items(state, items)

        total_items = item_count + new_item_count
        total_errors = error_count + new_error_count
        new_remote_ids = MapSet.union(remote_ids, MapSet.new(items, & &1.id))

        updated_max =
          case {max_updated_at, new_max_updated_at} do
            {nil, new} -> new
            {old, nil} -> old
            {old, new} -> if DateTime.compare(new, old) == :gt, do: new, else: old
          end

        if new_cursor do
          do_paginate(state, new_cursor, total_items, total_errors, updated_max, new_remote_ids)
        else
          {:ok, total_items, total_errors, updated_max, new_remote_ids}
        end

      {:error, reason} ->
        SyncLogger.error(collection.id, "Failed to list items: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp process_items(state, items) do
    %{
      conn: conn,
      connector: connector,
      collection: collection,
      source: source,
      actor: actor,
      existing_by_external_id: existing_by_external_id
    } = state

    cid = collection.id

    Enum.reduce(items, {0, 0, nil}, fn item, {item_count, error_count, max_updated_at} ->
      updated_max =
        case {max_updated_at, Map.get(item, :updated_at)} do
          {_, nil} -> max_updated_at
          {nil, new} -> new
          {old, new} -> if DateTime.compare(new, old) == :gt, do: new, else: old
        end

      case Map.get(existing_by_external_id, item.id) do
        nil ->
          case create_file_from_item(conn, connector, item, collection, source, actor) do
            {:ok, _file} ->
              SyncLogger.info(cid, "Synced: #{item.name}")
              {item_count + 1, error_count, updated_max}

            {:error, reason} ->
              Logger.warning(
                "FullSync: failed to create file for item #{item.id}: #{inspect(reason)}"
              )

              SyncLogger.error(cid, "Failed to sync #{item.name}: #{inspect(reason)}")
              {item_count, error_count + 1, updated_max}
          end

        file ->
          needs_check? = is_nil(item.etag) or file.external_etag != item.etag

          if needs_check? do
            case SyncHelpers.update_existing_file(conn, connector, file, item, actor) do
              {:ok, :updated} ->
                SyncLogger.info(cid, "Updated: #{item.name}")
                {item_count + 1, error_count, updated_max}

              {:ok, :unchanged} ->
                {item_count + 1, error_count, updated_max}

              {:error, reason} ->
                SyncLogger.error(cid, "Failed to update #{item.name}: #{inspect(reason)}")
                {item_count, error_count + 1, updated_max}
            end
          else
            {item_count + 1, error_count, updated_max}
          end
      end
    end)
  end

  # Hard-deletes local files absent from the complete remote listing. Only
  # called from the success path of `do_paginate/6` (a complete pagination),
  # never after a mid-pagination error: a partial listing would otherwise be
  # mistaken for a full remote inventory and mass-delete files that are
  # simply on a page we never reached.
  defp delete_remote_gone_files(state, remote_ids) do
    %{collection: collection, existing_by_external_id: existing_by_external_id} = state
    cid = collection.id

    gone =
      existing_by_external_id
      |> Enum.reject(fn {ext_id, _file} -> MapSet.member?(remote_ids, ext_id) end)

    Enum.each(gone, fn {_ext_id, file} -> SyncHelpers.delete_remote_gone_file(file) end)

    if gone != [] do
      SyncLogger.info(cid, "Hard-deleted #{length(gone)} remotely removed files")
    end
  end

  @doc """
  Fetches content for a remote item and creates a File record.

  This function is public because `IncrementalSync` calls it for newly
  created items.
  """
  def create_file_from_item(conn, connector, item, collection, source, actor) do
    case apply(connector, :fetch_content, [conn, item]) do
      {:ok, content, metadata} ->
        # For Google Workspace files (and similar), the connector exports to a
        # standard format (e.g. Docs → Markdown).  Use the export MIME type so
        # downstream extraction (Kreuzberg) receives a type it understands.
        effective_mime = Map.get(metadata || %{}, "export_mime", item.mime_type)

        file_id = Ash.UUIDv7.generate()
        file_size = byte_size(content)
        storage_path = Storage.generate_path(source.user_id, file_id, item.name)

        # external_etag is the LIST-TIME etag (item.etag): it is what future
        # list_items/detect_changes results are compared against. The
        # fetch-time content fingerprint lives in metadata["content_hash"]
        # and powers the update path's hash guard.
        case Storage.store(storage_path, content) do
          {:ok, _} ->
            Magus.Files.create_file_from_connector(
              %{
                name: item.name,
                type: detect_file_type(effective_mime),
                mime_type: effective_mime,
                file_size: file_size,
                file_path: storage_path,
                knowledge_collection_id: collection.id,
                external_id: item.id,
                external_etag: item.etag,
                external_updated_at: item.updated_at,
                metadata: %{
                  "source_provider" => source.provider,
                  "content_hash" => SyncHelpers.content_hash(content)
                }
              },
              actor: actor
            )

          {:error, reason} ->
            {:error, {:storage_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_existing_files(collection) do
    Magus.Files.File
    |> Ash.Query.filter(
      knowledge_collection_id == ^collection.id and
        not is_nil(external_id) and
        is_nil(deleted_at)
    )
    |> Ash.read!(authorize?: false)
  end

  @doc false
  def detect_file_type(mime_type) when is_binary(mime_type) do
    cond do
      String.starts_with?(mime_type, "image/") -> :image
      String.starts_with?(mime_type, "video/") -> :video
      String.starts_with?(mime_type, "text/") -> :text
      mime_type in ~w(message/rfc822 message/partial) -> :email
      true -> :document
    end
  end

  def detect_file_type(_), do: :document
end
