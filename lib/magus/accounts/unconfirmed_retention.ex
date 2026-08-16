defmodule Magus.Accounts.UnconfirmedRetention do
  @moduledoc """
  Reaps password-signup accounts that never confirmed their email
  (spec: signup-abuse-hardening, section C). v1 deliberately reaps ONLY
  users with no owned structure — org owners and sole-admin workspace
  holders are skipped with a warning (magus-xjc3 tracks teardown). All
  internal lookups run authorize?: false: there is no actor in the Oban
  context and user-facing policies would hide exactly the rows we check.
  """

  require Logger

  import Ecto.Query

  alias Magus.Accounts.AccountDeletion
  alias Magus.Accounts.User
  alias Magus.Repo

  @spec ttl_days() :: pos_integer() | nil
  def ttl_days, do: Application.get_env(:magus, :unconfirmed_account_ttl_days)

  @spec validate_config!() :: :ok
  def validate_config! do
    case ttl_days() do
      nil ->
        :ok

      days when is_integer(days) and days >= 1 ->
        :ok

      other ->
        raise "unconfirmed_account_ttl_days must be nil or an integer >= 1 " <>
                "(the reaper's scheduler floor is 1 day), got: #{inspect(other)}"
    end
  end

  @doc """
  Reaps `user` if it is an unconfirmed, past-TTL, structure-free account.

  Returns `:deleted` when the account was hard-deleted, `:skipped` when a
  guard (owned structure, or the final precondition check inside
  `AccountDeletion`) refused the delete, and `:noop` when the account
  simply isn't a reap candidate (confirmed, too young, or TTL disabled).

  Reloads `user` from the DB first: the AshOban trigger's own
  `worker_read_action` already does this immediately before invoking the
  action this function backs, so in production `user` is already fresh;
  reloading defensively here means every check below (confirmed_at, TTL,
  ownership) runs against current data regardless of caller. This is an
  advisory freshness improvement, not the race guarantee — the actual
  race-safety mechanism is the conditional row DELETE inside
  `AccountDeletion.execute/2`, which stays correct even if this reload
  were removed.
  """
  @spec reap(User.t()) :: :deleted | :skipped | :noop
  def reap(user) do
    case reload(user) do
      nil -> :noop
      user -> do_reap(user)
    end
  end

  defp do_reap(user) do
    days = ttl_days()

    cond do
      is_nil(days) ->
        :noop

      not is_nil(user.confirmed_at) ->
        :noop

      not past_ttl?(user, days) ->
        :noop

      owns_structure?(user) ->
        Logger.warning(
          "skipping reap of #{user.id}: owns an organization or is sole workspace admin"
        )

        :skipped

      true ->
        delete_if_still_unconfirmed(user)
    end
  end

  defp reload(user) do
    Ash.reload!(user, authorize?: false)
  rescue
    Ash.Error.Query.NotFound -> nil
  end

  defp delete_if_still_unconfirmed(user) do
    case AccountDeletion.execute(user, require_unconfirmed: true) do
      :ok ->
        Logger.info("reaped unconfirmed account #{user.id}")
        :deleted

      {:error, reason} ->
        Logger.warning("reap of #{user.id} did not delete: #{inspect(reason)}")
        :skipped
    end
  end

  defp past_ttl?(user, days) do
    DateTime.compare(
      user.inserted_at,
      DateTime.add(DateTime.utc_now(), -days * 86_400, :second)
    ) == :lt
  end

  defp owns_structure?(user) do
    owns_org?(user) or sole_admin_of_any_workspace?(user)
  end

  defp owns_org?(user) do
    Repo.exists?(from(o in "organizations", where: o.owner_id == type(^user.id, :binary_id)))
  end

  defp sole_admin_of_any_workspace?(user) do
    AccountDeletion.sole_admin_workspace_ids(user) != []
  end
end
