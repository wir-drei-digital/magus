defmodule Magus.Accounts.Workers.DeleteExpiredTestAccounts do
  @moduledoc """
  Daily cron worker that hard-deletes workshop/demo test accounts whose
  `test_account_expires_at` has passed.

  Deletion goes through `Magus.Accounts.AccountDeletion.execute/1` — the same
  path as a user-initiated account deletion — so all owned content, external
  resources, and (the non-existent, for test accounts) Stripe subscription are
  cleaned up. Per-account failures are logged and skipped so one bad row never
  blocks the rest of the sweep.

  Registered in the Oban crontab in `config/config.exs`.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3

  require Ash.Query
  require Logger

  alias Magus.Accounts.AccountDeletion
  alias Magus.Accounts.User

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: sweep()

  @doc """
  Reads all expired test accounts and deletes them. Returns
  `{:ok, %{deleted: n, failed: m}}`. Public so tests can drive it directly.
  """
  def sweep do
    now = DateTime.utc_now()

    expired =
      User
      |> Ash.Query.filter(
        test_account == true and not is_nil(test_account_expires_at) and
          test_account_expires_at < ^now
      )
      |> Ash.read!(authorize?: false)

    results = Enum.map(expired, &delete_account/1)
    deleted = Enum.count(results, &(&1 == :ok))
    failed = length(results) - deleted

    if deleted > 0 or failed > 0 do
      Logger.info("DeleteExpiredTestAccounts: deleted #{deleted}, failed #{failed}")
    end

    {:ok, %{deleted: deleted, failed: failed}}
  end

  defp delete_account(user) do
    case AccountDeletion.execute(user) do
      :ok ->
        :ok

      other ->
        Logger.warning(
          "DeleteExpiredTestAccounts: failed to delete #{user.email}: #{inspect(other)}"
        )

        :error
    end
  rescue
    e ->
      Logger.warning(
        "DeleteExpiredTestAccounts: crashed deleting #{user.email}: #{Exception.message(e)}"
      )

      :error
  end
end
