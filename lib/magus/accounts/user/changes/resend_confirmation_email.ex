defmodule Magus.Accounts.User.Changes.ResendConfirmationEmail do
  @moduledoc """
  Generates a fresh confirmation token (outside the monitored-field flow,
  via the public AshAuthentication API) and sends it. Guarded to
  unconfirmed users: a confirmed user re-running :confirm would replay
  SendWelcomeEmail. Rate-limited per email.
  """
  use Ash.Resource.Change

  alias Magus.Accounts.AuthRateLimiter

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, user ->
      with nil <- user.confirmed_at,
           :ok <-
             AuthRateLimiter.check(:resend_confirmation, String.downcase(to_string(user.email))) do
        strategy = AshAuthentication.Info.strategy!(Magus.Accounts.User, :confirm_new_user)

        token_changeset =
          user
          |> Ash.Changeset.new()
          |> Ash.Changeset.force_change_attribute(:email, user.email)

        case AshAuthentication.AddOn.Confirmation.confirmation_token(
               strategy,
               token_changeset,
               user
             ) do
          {:ok, token} ->
            Magus.Accounts.User.Senders.SendNewUserConfirmationEmail.send(user, token, [])
            {:ok, user}

          {:error, reason} ->
            {:error, reason}
        end
      else
        # already confirmed, or rate limited: silent no-op either way
        _ -> {:ok, user}
      end
    end)
  end
end
