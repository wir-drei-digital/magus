defmodule Magus.Integrations.Credential.Changes.ProcessExpiryWarning do
  @moduledoc """
  Oban-triggered change backing the daily credential-expiry sweep.

  Handles one credential per invocation (gated upstream by
  `Credential.expiring_soon`, which the `:warn_expiring` trigger's `where`
  clause uses to select candidates):

    * **Expired** (`expires_at` in the past) — marks the linked
      `UserIntegration` `:mark_errored` (idempotent: a no-op if it's already
      `:error`) and notifies the owner, once, on the transition into
      `:error`.
    * **Expiring soon** (within the 7-day window, not yet warned) — stamps
      `expiry_warned_at` and notifies the owner. `expiry_warned_at` is the
      de-dupe key: once set, `Credential.expiring_soon` excludes the
      credential until `expires_at` changes again (see `:refresh_token`,
      which clears `expiry_warned_at` whenever `expires_at` is updated) so a
      re-issued token gets its own fresh warning window.

  Future hook: no provider currently exposes a generic "refresh this token"
  callback on `Providers.Behaviour` — `GoogleCalendar.Provider.refresh_token/1`
  is a one-off helper, not part of the behaviour contract. If/when providers
  gain a uniform refresh callback, this change is the natural place to
  attempt a refresh before warning (only falling through to notify the
  owner if the refresh itself fails).
  """

  use Ash.Resource.Change

  require Logger

  alias Magus.Integrations

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, credential ->
      case Ash.get(Magus.Integrations.Credential, credential.id, authorize?: false) do
        {:ok, current} ->
          {:ok, handle(current)}

        {:error, reason} ->
          Logger.warning(
            "ProcessExpiryWarning: could not reload credential #{credential.id}: #{inspect(reason)}"
          )

          {:ok, credential}
      end
    end)
  end

  defp handle(%{expires_at: nil} = credential), do: credential

  defp handle(%{expires_at: expires_at} = credential) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :lt do
      handle_expired(credential)
    else
      handle_expiring_soon(credential)
    end
  end

  defp handle_expiring_soon(%{expiry_warned_at: %DateTime{}} = credential), do: credential

  defp handle_expiring_soon(credential) do
    case credential
         |> Ash.Changeset.for_update(:mark_expiry_warned, %{})
         |> Ash.update(authorize?: false) do
      {:ok, updated} ->
        case get_integration(updated) do
          {:ok, integration} ->
            notify_owner(
              integration,
              "Integration credential expiring soon",
              "Your #{integration.provider_key} credential will expire within 7 days. Reconnect it soon to avoid interruption."
            )

          {:error, reason} ->
            Logger.warning(
              "ProcessExpiryWarning: could not load integration for credential #{credential.id}: #{inspect(reason)}"
            )
        end

        updated

      {:error, reason} ->
        Logger.warning(
          "ProcessExpiryWarning: failed to stamp expiry_warned_at for credential #{credential.id}: #{inspect(reason)}"
        )

        credential
    end
  end

  defp handle_expired(credential) do
    case get_integration(credential) do
      {:ok, %{status: :error}} ->
        # Already errored: don't re-notify on every subsequent daily tick.
        :ok

      {:ok, integration} ->
        case Integrations.mark_integration_errored(integration, authorize?: false) do
          {:ok, _errored} ->
            notify_owner(
              integration,
              "Integration credential expired",
              "Your #{integration.provider_key} credential has expired and the integration has been disabled. Reconnect it to resume."
            )

          {:error, reason} ->
            Logger.warning(
              "ProcessExpiryWarning: failed to mark integration #{integration.id} errored: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.warning(
          "ProcessExpiryWarning: could not load integration for credential #{credential.id}: #{inspect(reason)}"
        )
    end

    credential
  end

  defp get_integration(credential) do
    Ash.get(Magus.Integrations.UserIntegration, credential.user_integration_id, authorize?: false)
  end

  defp notify_owner(integration, title, body) do
    case Magus.Notifications.create_notification(
           %{
             user_id: integration.user_id,
             notification_type: :system,
             title: title,
             body: body,
             metadata: %{
               integration_id: integration.id,
               provider_key: integration.provider_key
             }
           },
           authorize?: false
         ) do
      {:ok, _notification} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ProcessExpiryWarning: failed to notify owner for integration #{integration.id}: #{inspect(reason)}"
        )
    end
  end
end
