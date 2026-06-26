defmodule Magus.Usage.Account.Validations.BillingPreferences do
  @moduledoc """
  Validates user-editable pay-as-you-go preferences: the monthly spend cap must
  be a non-negative integer number of cents (nil = use the platform default).
  """
  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :monthly_spend_cap_cents) do
      nil ->
        :ok

      n when is_integer(n) and n >= 0 ->
        :ok

      _ ->
        {:error,
         field: :monthly_spend_cap_cents, message: "must be a non-negative number of cents"}
    end
  end
end
