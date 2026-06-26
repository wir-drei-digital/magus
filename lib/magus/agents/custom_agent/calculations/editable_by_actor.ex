defmodule Magus.Agents.CustomAgent.Calculations.EditableByActor do
  @moduledoc """
  Whether the current actor may update the agent — drives the SPA's
  inspect-vs-edit split: shared-agent viewers get a read-only view instead
  of auto-saving inputs whose failures only surface as error banners.
  """

  use Ash.Resource.Calculation

  # Ash.can? builds a real update changeset, so the action's validations and
  # policies evaluate against the record — load the fields they read
  # (HandleFormat → :handle; workspace policies → :user_id/:workspace_id).
  @impl true
  def load(_query, _opts, _context), do: [:handle, :user_id, :workspace_id]

  @impl true
  def calculate(records, _opts, %{actor: nil}), do: Enum.map(records, fn _ -> false end)

  def calculate(records, _opts, %{actor: actor}) do
    Enum.map(records, fn record ->
      Ash.can?({record, :update}, actor)
    end)
  end
end
