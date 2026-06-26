defmodule Magus.Usage.Account.Changes.PropagatePlanToSponsoredSubs do
  @moduledoc """
  When a personal `Account`'s `usage_plan_id` changes, mirror it onto
  every sponsored subscription where this user is the sponsor, and update
  every non-revoked grant they own.

  If the new plan no longer permits sponsorship (`sponsorable_seats` nil or 0),
  the existing sponsored subs are canceled and grants are revoked instead of
  mirrored — recipients fall back to their personal plan.

  Runs only when `usage_plan_id` actually changes on the personal sub.
  Skips sponsored subs themselves (`sponsor_user_id` is non-nil) to avoid loops.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    if Ash.Changeset.changing_attribute?(changeset, :usage_plan_id) do
      Ash.Changeset.after_action(changeset, fn _changeset, subscription ->
        if is_nil(subscription.sponsor_user_id) do
          propagate(subscription)
        end

        {:ok, subscription}
      end)
    else
      changeset
    end
  end

  defp propagate(sponsor_sub) do
    new_plan =
      Ash.get!(Magus.Usage.Policy, sponsor_sub.usage_plan_id, authorize?: false)

    if sponsoring_plan?(new_plan) do
      mirror_to_sponsored(sponsor_sub)
      # Seat grants are a billing-edition concept; core no-ops via the seam.
      Magus.Usage.SeatGrantSync.mirror_plan(sponsor_sub.user_id, sponsor_sub.usage_plan_id)
    else
      cancel_sponsored(sponsor_sub)
      Magus.Usage.SeatGrantSync.revoke_all(sponsor_sub.user_id)
    end
  end

  defp sponsoring_plan?(%{sponsorable_seats: n}) when is_integer(n) and n > 0, do: true
  defp sponsoring_plan?(_), do: false

  defp mirror_to_sponsored(sponsor_sub) do
    Magus.Usage.Account
    |> Ash.Query.filter(sponsor_user_id == ^sponsor_sub.user_id)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn sub ->
      sub
      |> Ash.Changeset.for_update(
        :update_sponsored_plan,
        %{usage_plan_id: sponsor_sub.usage_plan_id},
        authorize?: false
      )
      |> Ash.update!(authorize?: false)
    end)
  end

  defp cancel_sponsored(sponsor_sub) do
    Magus.Usage.Account
    |> Ash.Query.filter(sponsor_user_id == ^sponsor_sub.user_id and status != :canceled)
    |> Ash.read!(authorize?: false)
    |> Enum.each(fn sub ->
      sub
      |> Ash.Changeset.for_update(:update_sponsored_plan, %{status: :canceled}, authorize?: false)
      |> Ash.update!(authorize?: false)
    end)
  end
end
