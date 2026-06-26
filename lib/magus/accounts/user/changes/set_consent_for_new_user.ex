defmodule Magus.Accounts.User.Changes.SetConsentForNewUser do
  @moduledoc """
  Sets default consent flags (accepted_terms, accepted_age_requirement) for new users
  during magic link sign-in. Only applies to users that don't exist yet (new registrations).
  For existing users (upsert), the consent flags are not modified.

  Note: Consent validation is NOT enforced here. New magic link users complete their
  profile (including consent) via the /complete-profile page after sign-in.
  """
  use Ash.Resource.Change

  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      email = Ash.Changeset.get_attribute(changeset, :email)

      is_new_user =
        case Magus.Accounts.get_by_email(email, authorize?: false) do
          {:ok, _user} -> false
          {:error, _} -> true
        end

      if is_new_user do
        changeset
        |> Ash.Changeset.force_change_attribute(:accepted_terms, false)
        |> Ash.Changeset.force_change_attribute(:accepted_age_requirement, false)
      else
        changeset
      end
    end)
  end
end
