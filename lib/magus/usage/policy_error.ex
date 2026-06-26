defmodule Magus.Usage.PolicyError do
  @moduledoc """
  Structured policy-enforcement error. Carries only data; all human-facing copy
  lives in the core renderer (`Magus.Usage.PolicyErrorMessage`) so OSS and cloud
  can render different messaging from the same structured error.
  """
  defexception [:limit_type, :current, :limit, :upgrade_path]

  @type t :: %__MODULE__{
          limit_type:
            :spend_cap
            | :trial_cap
            | :payment_required
            | :mode_disabled
            | :storage_bytes
            | :storage_overage
            | :max_upload_bytes
            | :workspace_model_restricted,
          current: non_neg_integer() | nil,
          limit: non_neg_integer() | nil,
          upgrade_path: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{limit_type: type}),
    do: "usage policy error: #{type} (format via Magus.Usage.PolicyErrorMessage)"
end
