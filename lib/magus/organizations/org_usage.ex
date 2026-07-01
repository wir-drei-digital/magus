defmodule Magus.Organizations.OrgUsage do
  @moduledoc """
  Pooled + per-member spend for the org Usage tab. Spend is each member's
  `Account.period_usage_cents` (CHF cents). The owner sees every member; a
  non-owner member sees only their own row (pooled total stays visible).
  """
  require Ash.Query

  def for_organization(org_id, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, members} <-
           Magus.Organizations.list_active_org_members(org_id, authorize?: false),
         true <- Enum.any?(members, &(&1.user_id == actor.id)) || {:error, :forbidden} do
      owner? = Enum.any?(members, &(&1.user_id == actor.id and &1.role == :owner))
      rows = Enum.map(members, &member_row/1)
      pooled = Enum.sum(Enum.map(rows, & &1.spent_cents))

      visible = if owner?, do: rows, else: Enum.filter(rows, &(&1.user_id == actor.id))

      {:ok, %{pooled_spent_cents: pooled, seat_count: length(members), members: visible}}
    end
  end

  defp member_row(member) do
    member = Ash.load!(member, [:user], authorize?: false)

    spent =
      case Magus.Usage.get_user_subscription(member.user_id, authorize?: false) do
        {:ok, %{period_usage_cents: cents}} when is_integer(cents) -> cents
        _ -> 0
      end

    %{
      user_id: member.user_id,
      display_name: member.user && (member.user.display_name || to_string(member.user.email)),
      spent_cents: spent,
      cap_cents: member.spend_cap_cents
    }
  end
end
