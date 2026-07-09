defmodule Magus.Knowledge.KnowledgeCollection.Changes.IncrementalSync do
  @moduledoc """
  Ash change that performs an incremental sync of a KnowledgeCollection.

  Uses two strategies:
  1. **Delta API**: calls `connector.detect_changes/3` to get created/updated/deleted
     items since `last_synced_at`.
  2. **Fallback**: when the connector returns `:not_supported`, performs a full listing
     and compares etags against existing files to detect changes.
  """

  use Ash.Resource.Change

  require Ash.Query
  require Logger

  alias Magus.Knowledge.Connector
  alias Magus.Knowledge.KnowledgeCollection.Changes.FullSync
  alias Magus.Knowledge.KnowledgeCollection.Changes.SyncHelpers
  alias Magus.Knowledge.KnowledgeCollection.Changes.SyncLogger
  alias Magus.Knowledge.TokenManager

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, collection ->
      do_incremental_sync(collection)
      {:ok, collection}
    end)
  end

  @doc false
  def do_incremental_sync(collection) do
    collection = Ash.load!(collection, [knowledge_source: []], authorize?: false)

    if should_sync?(collection) do
      SyncLogger.info(collection.id, "Starting incremental sync")
      run_incremental_sync(collection)
    end
  end

  defp should_sync?(collection) do
    case collection.last_synced_at do
      nil ->
        true

      last_synced_at ->
        interval = collection.sync_interval_minutes || 60
        min_next_sync = DateTime.add(last_synced_at, interval * 60, :second)
        DateTime.compare(DateTime.utc_now(), min_next_sync) != :lt
    end
  end

  defp run_incremental_sync(collection) do
    source = collection.knowledge_source
    cid = collection.id

    case SyncHelpers.check_rate_limit(source) do
      {:error, :rate_limited} ->
        SyncLogger.warn(cid, "Rate limited, skipping sync")
        {:ok, collection}

      :ok ->
        case TokenManager.ensure_fresh(source) do
          {:error, :reauth_required} ->
            TokenManager.mark_source_reauth_required(source)
            update_sync_error(collection, :reauth_required)

          {:ok, source} ->
            case Connector.connector_for(source.provider) do
              {:error, _} = error ->
                update_sync_error(collection, error)

              connector ->
                SyncLogger.info(cid, "Connecting to #{source.provider}")

                case apply(connector, :connect, [source.auth_config]) do
                  {:ok, conn} ->
                    actor = Ash.get!(Magus.Accounts.User, source.user_id, authorize?: false)
                    result = do_sync(conn, connector, collection, source, actor)
                    SyncHelpers.maybe_persist_refreshed_token(conn, connector, source)
                    maybe_flag_reauth(result, source)
                    result

                  {:error, reason} ->
                    SyncLogger.error(cid, "Connection failed: #{inspect(reason)}")
                    update_sync_error(collection, reason)
                end
            end
        end
    end
  end

  # A mid-sync reactive refresh can also surface :reauth_required.
  defp maybe_flag_reauth({:error, :reauth_required}, source),
    do: TokenManager.mark_source_reauth_required(source)

  defp maybe_flag_reauth(_result, _source), do: :ok

  defp do_sync(conn, connector, collection, source, actor) do
    cid = collection.id
    since = collection.last_synced_at || ~U[1970-01-01 00:00:00Z]

    case apply(connector, :detect_changes, [conn, collection, since]) do
      {:ok, changes} ->
        SyncLogger.info(cid, "Delta sync: #{length(changes)} changes detected")
        delta_sync(conn, connector, changes, collection, source, actor, nil)

      {:ok, changes, cursor} ->
        SyncLogger.info(cid, "Delta sync: #{length(changes)} changes detected")
        delta_sync(conn, connector, changes, collection, source, actor, cursor)

      {:error, :not_supported} ->
        SyncLogger.info(cid, "Delta not supported, using fallback etag sync")
        fallback_sync(conn, connector, collection, source, actor)

      {:error, :reauth_required} ->
        update_sync_error(collection, :reauth_required)
        {:error, :reauth_required}

      {:error, reason} ->
        SyncLogger.error(cid, "detect_changes failed: #{inspect(reason)}")
        update_sync_error(collection, reason)
    end
  end

  # --- Delta-based sync ---

  defp delta_sync(conn, connector, changes, collection, source, actor, cursor) do
    cid = collection.id
    existing_files = get_existing_files(collection)
    existing_by_external_id = Map.new(existing_files, &{&1.external_id, &1})

    {_processed, error_count} =
      Enum.reduce(changes, {0, 0}, fn change, {items, errors} ->
        case process_change(
               conn,
               connector,
               change,
               existing_by_external_id,
               collection,
               source,
               actor
             ) do
          :ok ->
            {items + 1, errors}

          {:ok, msg} ->
            SyncLogger.info(cid, msg)
            {items + 1, errors}

          :error ->
            {items, errors + 1}

          {:error, msg} ->
            SyncLogger.error(cid, msg)
            {items, errors + 1}
        end
      end)

    now = DateTime.utc_now()

    {:ok, actual_count} =
      Magus.Files.File
      |> Ash.Query.filter(knowledge_collection_id == ^cid and is_nil(deleted_at))
      |> Ash.count(authorize?: false)

    SyncLogger.info(
      cid,
      "Incremental sync complete: #{actual_count} files, #{error_count} errors"
    )

    sync_attrs = %{
      sync_status: :synced,
      last_synced_at: now,
      item_count: actual_count,
      error_count: error_count,
      last_error: nil
    }

    sync_attrs =
      if cursor, do: Map.put(sync_attrs, :sync_cursor, cursor), else: sync_attrs

    Magus.Knowledge.update_sync_status(collection, sync_attrs, authorize?: false)
  end

  defp process_change(
         conn,
         connector,
         %{type: :created, item: item},
         existing,
         collection,
         source,
         actor
       ) do
    if Map.has_key?(existing, item.id) do
      process_change(
        conn,
        connector,
        %{type: :updated, item: item},
        existing,
        collection,
        source,
        actor
      )
    else
      case FullSync.create_file_from_item(conn, connector, item, collection, source, actor) do
        {:ok, _file} ->
          {:ok, "Created: #{item.name}"}

        {:error, reason} ->
          Logger.warning("IncrementalSync: failed to create item #{item.id}: #{inspect(reason)}")
          {:error, "Failed to create #{item.name}: #{inspect(reason)}"}
      end
    end
  end

  defp process_change(
         conn,
         connector,
         %{type: :updated, item: item},
         existing,
         collection,
         source,
         actor
       ) do
    case Map.get(existing, item.id) do
      nil ->
        # Google Drive's Changes API reports newly added files as :updated.
        # An update for an item we have never synced is a create, not a no-op.
        process_change(
          conn,
          connector,
          %{type: :created, item: item},
          existing,
          collection,
          source,
          actor
        )

      file ->
        case SyncHelpers.update_existing_file(conn, connector, file, item, actor) do
          {:ok, _outcome} ->
            {:ok, "Updated: #{item.name}"}

          {:error, reason} ->
            Logger.warning(
              "IncrementalSync: failed to update item #{item.id}: #{inspect(reason)}"
            )

            {:error, "Failed to update #{item.name}: #{inspect(reason)}"}
        end
    end
  end

  defp process_change(
         _conn,
         _connector,
         %{type: :deleted, item: item},
         existing,
         _collection,
         _source,
         _actor
       ) do
    case Map.get(existing, item.id) do
      nil ->
        :ok

      file ->
        case SyncHelpers.delete_remote_gone_file(file) do
          :ok -> {:ok, "Deleted: #{item.name || item.id}"}
          :error -> {:error, "Failed to delete: #{item.name || item.id}"}
        end
    end
  end

  # --- Fallback sync (etag comparison) ---

  defp fallback_sync(conn, connector, collection, source, actor) do
    cid = collection.id
    existing_files = get_existing_files(collection)
    existing_by_external_id = Map.new(existing_files, &{&1.external_id, &1})

    case list_all_remote_items(conn, connector, collection) do
      {:ok, remote_items} ->
        SyncLogger.info(cid, "Fallback: #{length(remote_items)} remote items found")
        remote_by_id = Map.new(remote_items, &{&1.id, &1})

        {_item_count, error_count} =
          Enum.reduce(remote_items, {0, 0}, fn item, {items, errors} ->
            case Map.get(existing_by_external_id, item.id) do
              nil ->
                case FullSync.create_file_from_item(
                       conn,
                       connector,
                       item,
                       collection,
                       source,
                       actor
                     ) do
                  {:ok, _} ->
                    SyncLogger.info(cid, "Created: #{item.name}")
                    {items + 1, errors}

                  {:error, reason} ->
                    Logger.warning(
                      "IncrementalSync fallback: failed to create #{item.id}: #{inspect(reason)}"
                    )

                    SyncLogger.error(cid, "Failed to create #{item.name}: #{inspect(reason)}")
                    {items, errors + 1}
                end

              file ->
                needs_check? = is_nil(item.etag) or file.external_etag != item.etag

                if needs_check? do
                  case SyncHelpers.update_existing_file(conn, connector, file, item, actor) do
                    {:ok, :updated} ->
                      SyncLogger.info(cid, "Updated: #{item.name}")
                      {items + 1, errors}

                    {:ok, :unchanged} ->
                      {items + 1, errors}

                    {:error, reason} ->
                      Logger.warning(
                        "IncrementalSync fallback: failed to update #{item.id}: #{inspect(reason)}"
                      )

                      SyncLogger.error(cid, "Failed to update #{item.name}: #{inspect(reason)}")
                      {items, errors + 1}
                  end
                else
                  {items + 1, errors}
                end
            end
          end)

        # Hard-delete files that no longer exist remotely
        deleted =
          existing_by_external_id
          |> Enum.reject(fn {ext_id, _file} -> Map.has_key?(remote_by_id, ext_id) end)

        if length(deleted) > 0 do
          Enum.each(deleted, fn {_ext_id, file} ->
            SyncHelpers.delete_remote_gone_file(file)
          end)

          SyncLogger.info(cid, "Hard-deleted #{length(deleted)} remotely removed files")
        end

        now = DateTime.utc_now()

        {:ok, actual_count} =
          Magus.Files.File
          |> Ash.Query.filter(knowledge_collection_id == ^cid and is_nil(deleted_at))
          |> Ash.count(authorize?: false)

        SyncLogger.info(
          cid,
          "Incremental sync complete: #{actual_count} files, #{error_count} errors"
        )

        Magus.Knowledge.update_sync_status(
          collection,
          %{
            sync_status: :synced,
            last_synced_at: now,
            item_count: actual_count,
            error_count: error_count,
            last_error: nil
          },
          authorize?: false
        )

      {:error, reason} ->
        update_sync_error(collection, reason)
    end
  end

  defp list_all_remote_items(conn, connector, collection) do
    do_list_all(conn, connector, collection, nil, [])
  end

  defp do_list_all(conn, connector, collection, cursor, acc) do
    case apply(connector, :list_items, [conn, collection, cursor]) do
      {:ok, items, nil} ->
        {:ok, [items | acc] |> Enum.reverse() |> List.flatten()}

      {:ok, items, new_cursor} ->
        do_list_all(conn, connector, collection, new_cursor, [items | acc])

      {:error, _} = error ->
        error
    end
  end

  # --- Shared helpers ---

  defp get_existing_files(collection) do
    Magus.Files.File
    |> Ash.Query.filter(
      knowledge_collection_id == ^collection.id and
        not is_nil(external_id) and
        is_nil(deleted_at)
    )
    |> Ash.read!(authorize?: false)
  end

  defp update_sync_error(collection, reason) do
    Logger.error("IncrementalSync failed for collection #{collection.id}: #{inspect(reason)}")
    SyncLogger.error(collection.id, "Incremental sync failed: #{inspect(reason)}")

    Magus.Knowledge.update_sync_status(
      collection,
      %{
        sync_status: :error,
        last_error: inspect(reason),
        error_count: (collection.error_count || 0) + 1
      },
      authorize?: false
    )

    {:ok, collection}
  end
end
