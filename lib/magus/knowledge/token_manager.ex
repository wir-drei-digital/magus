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

  Concurrency: Google's standard OAuth clients do not rotate refresh tokens, so
  concurrent refreshes across a source's collections are benign and we persist
  last-write-wins rather than holding a DB lock across the refresh HTTP call.
  """

  require Logger

  alias Magus.Knowledge
  alias Magus.Knowledge.OAuth

  # Refresh when the access token expires within this window.
  @refresh_skew_seconds 300

  @doc "Returns the source with a valid access token, or `{:error, :reauth_required}`."
  def ensure_fresh(%{provider: :google_drive} = source) do
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
    case OAuth.refresh_google_token(refresh_token) do
      {:ok, new_auth} ->
        persist(source, new_auth)

      {:error, :reauth_required} = err ->
        err

      {:error, reason} ->
        # Transient (network / 5xx / missing config): let the sync proceed and
        # rely on the connector's reactive 401 refresh rather than blocking.
        Logger.warning(
          "TokenManager: transient refresh failure for #{source.id}: #{inspect(reason)}"
        )

        {:ok, source}
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
