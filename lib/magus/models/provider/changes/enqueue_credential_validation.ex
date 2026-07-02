defmodule Magus.Models.Provider.Changes.EnqueueCredentialValidation do
  @moduledoc """
  After an owned provider write commits, enqueues a unique credential
  validation job keyed by `provider_id`. Skips global (admin-owned) rows,
  which have no `owner_user_id`.

  Only the provider id crosses into the job args: the `api_key` is never
  placed in Oban args, so it stays out of the jobs table, logs, and telemetry.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _cs, result ->
      with {:ok, %{owner_user_id: owner, id: id}} when is_binary(owner) <- result do
        %{provider_id: id}
        |> Magus.Models.Workers.ValidateCredential.new()
        |> Oban.insert()
      end

      result
    end)
  end
end
