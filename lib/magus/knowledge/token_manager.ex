defmodule Magus.Knowledge.TokenManager do
  @moduledoc """
  Owns "give me a valid access token for this knowledge source".

  Before each sync the sync jobs call `ensure_fresh/1`, which proactively
  refreshes a soon-to-expire Google access token and persists the result
  (including a rotated refresh token) immediately, so a later job never races on
  a stale token. A dead refresh token surfaces as `{:error, :reauth_required}`;
  the sync jobs then call `mark_source_reauth_required/1`, which flags the source
  (pausing its scheduled syncs, see the incremental_sync trigger) and notifies
  the owner once.

  Concurrency: refreshes persist last-write-wins rather than holding a DB lock
  across the refresh HTTP call. Google and kDrive do not rotate refresh
  tokens, so concurrent refreshes are benign there. Microsoft DOES rotate:
  two concurrent OneDrive refreshes can race, and the loser sees
  invalid_grant even though the winner just persisted a valid token. The
  loser recovers by re-reading the source and adopting the winner's newer
  persisted token (one retry) before flagging reauth; only an unchanged
  token is a real dead grant. Consider per-source serialization (advisory
  lock) if sync concurrency per source ever rises materially.
  """

  require Logger

  alias Magus.Knowledge
  alias Magus.Knowledge.OAuth

  # Refresh when the access token expires within this window.
  @refresh_skew_seconds 300

  # Providers with an OAuth refresh-token flow handled by `Magus.Knowledge.OAuth`.
  @refreshable [:google_drive, :onedrive, :dropbox]

  @doc "Returns the source with a valid access token, or `{:error, :reauth_required}`."
  def ensure_fresh(%{provider: provider} = source) when provider in @refreshable do
    auth = source.auth_config || %{}
    refresh_token = auth["refresh_token"]

    cond do
      not is_binary(refresh_token) ->
        {:ok, source}

      not expiring_soon?(auth["expires_at"]) ->
        {:ok, source}

      true ->
        do_refresh(source, refresh_token)
    end
  end

  # Providers without an OAuth refresh (notion, nextcloud, affine, web).
  def ensure_fresh(source), do: {:ok, source}

  @doc "Flags the source as needing reconnection and notifies the owner once."
  def mark_source_reauth_required(source) do
    already_flagged = Map.get(source, :needs_reauth, false)

    case Knowledge.mark_source_needs_reauth(source, %{last_error: "reauth_required"},
           authorize?: false
         ) do
      {:ok, _} ->
        unless already_flagged, do: notify_owner(source)
        :ok

      {:error, reason} ->
        Logger.warning(
          "TokenManager: failed to flag source #{source.id} for reauth: #{inspect(reason)}"
        )

        :ok
    end
  end

  defp do_refresh(source, refresh_token) do
    case OAuth.refresh_token(source.provider, refresh_token) do
      {:ok, new_auth} ->
        persist(source, new_auth)

      {:error, :reauth_required} = err ->
        retry_with_persisted_token(source, refresh_token, err)

      {:error, reason} ->
        # Transient (network / 5xx / missing config): let the sync proceed and
        # rely on the connector's reactive 401 refresh rather than blocking.
        Logger.warning(
          "TokenManager: transient refresh failure for #{source.id}: #{inspect(reason)}"
        )

        {:ok, source}
    end
  end

  # Rotating providers (Microsoft) invalidate the old refresh token on use, so
  # an invalid_grant may just mean a concurrent refresh by another collection
  # of the same source WON and persisted a newer token right before ours
  # failed. Re-read the source: if a different refresh token is persisted, use
  # the winner's state (retrying the refresh only if its access token is
  # already expiring again). Only an unchanged token is a real dead grant.
  defp retry_with_persisted_token(source, used_token, err) do
    case Knowledge.get_source(source.id, authorize?: false) do
      {:ok, %{auth_config: %{"refresh_token" => latest} = auth} = fresh}
      when is_binary(latest) and latest != used_token ->
        Logger.info(
          "TokenManager: refresh race on #{source.id}; a newer persisted token exists, recovering"
        )

        if expiring_soon?(auth["expires_at"]) do
          case OAuth.refresh_token(fresh.provider, latest) do
            {:ok, new_auth} ->
              persist(fresh, new_auth)

            {:error, :reauth_required} = err2 ->
              err2

            {:error, reason} ->
              Logger.warning(
                "TokenManager: transient refresh failure for #{source.id}: #{inspect(reason)}"
              )

              {:ok, fresh}
          end
        else
          {:ok, fresh}
        end

      _ ->
        err
    end
  end

  defp persist(source, new_auth) do
    merged = Map.merge(source.auth_config || %{}, new_auth)

    case Knowledge.update_source_auth_config(source, %{auth_config: merged}, authorize?: false) do
      {:ok, updated} ->
        if Map.get(source, :needs_reauth, false) do
          Knowledge.clear_source_reauth(updated, authorize?: false)
        end

        {:ok, updated}

      {:error, reason} ->
        Logger.warning(
          "TokenManager: failed to persist refreshed token for #{source.id}: #{inspect(reason)}"
        )

        # Still return the in-memory refreshed config so this sync uses it.
        {:ok, %{source | auth_config: merged}}
    end
  end

  defp expiring_soon?(nil), do: false

  defp expiring_soon?(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} ->
        DateTime.compare(DateTime.utc_now(), DateTime.add(dt, -@refresh_skew_seconds, :second)) !=
          :lt

      _ ->
        false
    end
  end

  defp notify_owner(source) do
    Magus.Notifications.create_notification(
      %{
        user_id: source.user_id,
        notification_type: :system,
        title: "Reconnect #{source.name}",
        body: "#{source.name} lost access and stopped syncing. Reconnect it to resume.",
        metadata: %{"knowledge_source_id" => source.id}
      },
      authorize?: false
    )
  end
end
