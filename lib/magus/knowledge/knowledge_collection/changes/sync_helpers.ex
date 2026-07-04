defmodule Magus.Knowledge.KnowledgeCollection.Changes.SyncHelpers do
  @moduledoc """
  Shared helpers for FullSync and IncrementalSync change modules.
  """

  require Logger

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
end
