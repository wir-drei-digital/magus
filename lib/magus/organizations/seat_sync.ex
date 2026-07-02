defmodule Magus.Organizations.SeatSync do
  @moduledoc """
  Billing seam fired on organization membership changes. Core default is a
  no-op; the cloud edition configures an impl that adjusts the org's Stripe
  seat quantity and runs the mid-cycle takeover / revert-to-personal flows.
  """
  @callback on_member_activated(member_id :: binary()) :: :ok
  @callback on_member_removed(member_id :: binary()) :: :ok
  @callback on_organization_archived(organization_id :: binary()) :: :ok
  @callback on_ownership_transferred(organization_id :: binary()) :: :ok

  @spec on_member_activated(binary()) :: :ok
  def on_member_activated(member_id), do: impl().on_member_activated(member_id)

  @spec on_member_removed(binary()) :: :ok
  def on_member_removed(member_id), do: impl().on_member_removed(member_id)

  @spec on_organization_archived(binary()) :: :ok
  def on_organization_archived(organization_id),
    do: impl().on_organization_archived(organization_id)

  @spec on_ownership_transferred(binary()) :: :ok
  def on_ownership_transferred(organization_id),
    do: impl().on_ownership_transferred(organization_id)

  defp impl, do: Application.get_env(:magus, __MODULE__, [])[:impl] || __MODULE__.Noop

  defmodule Noop do
    @moduledoc false
    @behaviour Magus.Organizations.SeatSync
    @impl true
    def on_member_activated(_member_id), do: :ok
    @impl true
    def on_member_removed(_member_id), do: :ok
    @impl true
    def on_organization_archived(_organization_id), do: :ok
    @impl true
    def on_ownership_transferred(_organization_id), do: :ok
  end
end
