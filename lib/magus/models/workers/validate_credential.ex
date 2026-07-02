defmodule Magus.Models.Workers.ValidateCredential do
  @moduledoc """
  Stamps a provider's credential validation status. Unique per provider over a
  short window so a burst of edits cannot fan out into many probes.

  The provider's `api_key` is never read into args, logs, or telemetry here:
  the worker loads the provider by id and delegates the probe to
  `Magus.Models.CredentialValidator`.
  """
  use Oban.Worker,
    queue: :default,
    unique: [period: 60, fields: [:args], keys: [:provider_id]]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"provider_id" => provider_id}}) do
    case Ash.get(Magus.Models.Provider, provider_id, authorize?: false) do
      {:ok, provider} ->
        status = Magus.Models.CredentialValidator.validate(provider)

        provider
        |> Ash.Changeset.for_update(:stamp_validation, %{
          validation_status: status,
          last_validated_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ash.update!(authorize?: false)

        :ok

      _ ->
        :ok
    end
  end
end
