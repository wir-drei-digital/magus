defmodule Magus.Usage.SeatGrantSync do
  @moduledoc """
  Seam for propagating a personal sponsor's plan change onto their commercial
  seat grants.

  Sponsored paid seats are a billing-edition concept (`Magus.Billing.SeatGrant`),
  so core defaults to a no-op: a pure OSS install has no seat grants to update.
  The combined hosted app configures `Magus.Billing.SeatGrantSync`, which mirrors
  or revokes the sponsor's grants. Wired like the other open-core seams via
  `config :magus, Magus.Usage.SeatGrantSync, impl: ...`.
  """

  @callback mirror_plan(sponsor_user_id :: binary(), usage_plan_id :: binary()) :: :ok
  @callback revoke_all(sponsor_user_id :: binary()) :: :ok

  @doc "Mirror the sponsor's new plan onto their non-revoked seat grants."
  @spec mirror_plan(binary(), binary()) :: :ok
  def mirror_plan(sponsor_user_id, usage_plan_id),
    do: impl().mirror_plan(sponsor_user_id, usage_plan_id)

  @doc "Revoke all of the sponsor's non-revoked seat grants."
  @spec revoke_all(binary()) :: :ok
  def revoke_all(sponsor_user_id), do: impl().revoke_all(sponsor_user_id)

  defp impl,
    do: Application.get_env(:magus, __MODULE__, [])[:impl] || __MODULE__.Noop

  defmodule Noop do
    @moduledoc false
    @behaviour Magus.Usage.SeatGrantSync
    @impl true
    def mirror_plan(_sponsor_user_id, _usage_plan_id), do: :ok
    @impl true
    def revoke_all(_sponsor_user_id), do: :ok
  end
end
