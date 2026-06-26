defmodule Magus.Usage.BillingStatusProvider do
  @moduledoc """
  Resolves a user's billing status for the spend gate. Core default reads the
  `status` column on the account (correct for both self-host and the combined
  hosted app in Step A). At the repo split, the cloud edition overrides this to
  read live from Stripe and the self-host default returns `:active`.
  """
  @type status :: :active | :trialing | :past_due | :canceled

  @callback status_for_user(user_id :: binary()) :: status()

  @doc "Dispatch to the configured implementation (default: this module)."
  @spec status_for_user(binary()) :: status()
  def status_for_user(user_id), do: impl().status_for_user(user_id)

  defp impl,
    do: Application.get_env(:magus, __MODULE__, [])[:impl] || __MODULE__.Default

  defmodule Default do
    @moduledoc false
    @behaviour Magus.Usage.BillingStatusProvider

    @impl true
    def status_for_user(user_id) do
      case Magus.Usage.get_user_subscription(user_id, authorize?: false) do
        {:ok, %{status: status}} when not is_nil(status) -> status
        _ -> :active
      end
    end
  end
end
