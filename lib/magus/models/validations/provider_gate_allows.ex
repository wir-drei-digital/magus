defmodule Magus.Models.Validations.ProviderGateAllows do
  @moduledoc "Applies the ProviderGate seam on create and on credential changes."
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, %{actor: %{} = actor}) do
    credential_change? =
      Ash.Changeset.changing_attribute?(changeset, :api_key) or
        Ash.Changeset.changing_attribute?(changeset, :base_url)

    if changeset.action_type == :create or credential_change? do
      case Magus.Models.ProviderGate.can_create?(actor) do
        :ok -> :ok
        {:error, reason} -> {:error, field: :base, message: to_string(reason)}
      end
    else
      :ok
    end
  end

  def validate(_changeset, _opts, _context),
    do: {:error, field: :base, message: "requires an actor"}
end
