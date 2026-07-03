defmodule Magus.Organizations.OrgUsage do
  @moduledoc """
  Pooled + per-member spend for the org Usage tab. Spend is each member's
  `Account.period_usage_cents` (CHF cents); tokens are each member's summed
  `MessageUsage` prompt+completion over the current billing period. The owner
  sees every member; a non-owner member sees only their own row (pooled totals
  stay visible).
  """
  import Ecto.Query

  def for_organization(org_id, opts) do
    actor = Keyword.fetch!(opts, :actor)

    with {:ok, members} <-
           Magus.Organizations.list_active_org_members(org_id, authorize?: false),
         true <-
           Enum.any?(members, &(&1.user_id == actor.id)) ||
             {:error, Ash.Error.Forbidden.exception([])} do
      owner? = Enum.any?(members, &(&1.user_id == actor.id and &1.role == :owner))

      tokens_by_user = tokens_by_user(org_id, members)
      rows = Enum.map(members, &member_row(&1, tokens_by_user))

      pooled = Enum.sum(Enum.map(rows, & &1.spent_cents))
      pooled_tokens = Enum.sum(Enum.map(rows, & &1.tokens))

      visible = if owner?, do: rows, else: Enum.filter(rows, &(&1.user_id == actor.id))

      {:ok,
       %{
         pooled_spent_cents: pooled,
         pooled_tokens: pooled_tokens,
         seat_count: length(members),
         # The UI titles the member table by scope ("Per-member spend" vs
         # "Your spend"), so the viewer's role travels with the data it scopes.
         viewer_owner: owner?,
         members: visible
       }}
    end
  end

  defp member_row(member, tokens_by_user) do
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
      cap_cents: member.spend_cap_cents,
      tokens: Map.get(tokens_by_user, member.user_id, 0)
    }
  end

  # One grouped aggregate over MessageUsage for every member at once (no
  # per-member N+1). Members with no usage are absent from the map -> 0.
  defp tokens_by_user(org_id, members) do
    user_ids = members |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1)

    if user_ids == [] do
      %{}
    else
      period_start = period_start(org_id)

      from(u in Magus.Usage.MessageUsage,
        where: u.user_id in ^user_ids and u.inserted_at >= ^period_start,
        group_by: u.user_id,
        select: {u.user_id, sum(u.prompt_tokens) + sum(u.completion_tokens)}
      )
      |> Magus.Repo.all()
      |> Map.new(fn {uid, tokens} -> {uid, to_int(tokens)} end)
    end
  end

  # The org's current billing-period start, or the start of the current calendar
  # month (UTC) when the org has no period set yet.
  defp period_start(org_id) do
    case Ash.get(Magus.Organizations.Organization, org_id, authorize?: false) do
      {:ok, %{current_period_start: %DateTime{} = start}} -> start
      _ -> start_of_month()
    end
  end

  defp start_of_month do
    today = Date.utc_today()
    DateTime.new!(%{today | day: 1}, ~T[00:00:00], "Etc/UTC")
  end

  # SUM(integer) can cross Ecto as integer or Decimal; coerce defensively.
  defp to_int(nil), do: 0
  defp to_int(%Decimal{} = decimal), do: Decimal.to_integer(decimal)
  defp to_int(value) when is_integer(value), do: value
  defp to_int(value) when is_float(value), do: trunc(value)
end
