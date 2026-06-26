defmodule Magus.Accounts.User.Changes.SendWelcomeEmail do
  @moduledoc """
  Sends a welcome email when a user becomes fully onboarded.

  A user is "fully onboarded" when both `confirmed_at` and `accepted_terms`
  are set. This change detects the transition — it only fires when the user
  was NOT fully onboarded before the action but IS after.

  Covers all registration paths:
  - Password users: fires when `confirm_new_user` sets `confirmed_at`
    (they already have `accepted_terms` from registration)
  - Magic link users: fires when `complete_profile` sets `accepted_terms`
    (they were auto-confirmed on sign-in)
  - Grandfathered users: same as magic link
  """

  use Ash.Resource.Change

  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, user ->
      was_onboarded? = changeset.data.confirmed_at != nil && changeset.data.accepted_terms == true
      now_onboarded? = user.confirmed_at != nil && user.accepted_terms == true

      if now_onboarded? && !was_onboarded? do
        Task.start(fn ->
          case Magus.Mail.send_welcome(user) do
            {:ok, _} ->
              Logger.debug("Sent welcome email to #{user.email}")

            {:error, reason} ->
              Logger.warning("Failed to send welcome email to #{user.email}: #{inspect(reason)}")
          end
        end)
      end

      {:ok, user}
    end)
  end
end
