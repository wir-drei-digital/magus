defmodule Magus.Models.ProviderGate do
  @moduledoc """
  Deployment seam gating BYOK provider creation and credential updates.
  Open-core default allows everything; the cloud edition swaps the module
  via `config :magus, :provider_gate` to require a paid or trialing
  subscription. Never consulted on the resolution hot path, and a lapsed
  subscription never disables existing providers.
  """
  @callback can_create?(user :: struct()) :: :ok | {:error, atom()}

  def impl, do: Application.get_env(:magus, :provider_gate, __MODULE__.Open)
  def can_create?(user), do: impl().can_create?(user)

  defmodule Open do
    @moduledoc "Open-core default: BYOK provider creation is always allowed."
    @behaviour Magus.Models.ProviderGate
    @impl true
    def can_create?(_user), do: :ok
  end
end
