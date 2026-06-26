defmodule Magus.Usage.AccountLifecycle do
  @moduledoc """
  Hooks for account lifecycle side effects the billing edition owns. Core
  defaults are no-ops; the combined hosted app configures the Billing impl,
  which cancels a Stripe subscription before account deletion.
  """
  @callback on_deletion(user_id :: binary()) :: :ok | {:error, term()}
  @callback on_registration(user_id :: binary()) :: :ok

  @spec on_deletion(binary()) :: :ok | {:error, term()}
  def on_deletion(user_id), do: impl().on_deletion(user_id)

  @spec on_registration(binary()) :: :ok
  def on_registration(user_id), do: impl().on_registration(user_id)

  defp impl,
    do: Application.get_env(:magus, __MODULE__, [])[:impl] || __MODULE__.Noop

  defmodule Noop do
    @moduledoc false
    @behaviour Magus.Usage.AccountLifecycle
    @impl true
    def on_deletion(_user_id), do: :ok
    @impl true
    def on_registration(_user_id), do: :ok
  end
end
