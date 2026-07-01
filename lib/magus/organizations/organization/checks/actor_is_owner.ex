defmodule Magus.Organizations.Organization.Checks.ActorIsOwner do
  @moduledoc """
  Policy check: the actor is the organization's denormalized owner
  (`owner_id`). Reads `organization_id` from the generic action's input
  arguments. Used to owner-gate generic actions (e.g. `org_billing_overview`)
  where filter checks are unavailable.
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is the organization owner"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{action_input: %Ash.ActionInput{} = input}, _opts) do
    case Ash.ActionInput.get_argument(input, :organization_id) do
      nil -> false
      organization_id -> owner?(organization_id, actor.id)
    end
  end

  def match?(_actor, _context, _opts), do: false

  defp owner?(organization_id, user_id) do
    case Ash.get(Magus.Organizations.Organization, organization_id, authorize?: false) do
      {:ok, %{owner_id: ^user_id}} -> true
      _ -> false
    end
  end
end
