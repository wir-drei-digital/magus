defmodule Magus.Organizations.Organization.Checks.ActorIsOwner do
  @moduledoc """
  Policy check: the actor is the organization's denormalized owner
  (`owner_id`).

  Two shapes are supported: generic actions read `organization_id` from the
  action input arguments (e.g. `org_billing_overview`), and update actions read
  `owner_id` off the changeset's record (e.g. `archive`) where filter checks
  would work but a named check keeps the owner rule reusable.
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

  def match?(actor, %{changeset: %Ash.Changeset{data: %{owner_id: owner_id}}}, _opts)
      when not is_nil(owner_id) do
    owner_id == actor.id
  end

  def match?(_actor, _context, _opts), do: false

  defp owner?(organization_id, user_id) do
    case Ash.get(Magus.Organizations.Organization, organization_id, authorize?: false) do
      {:ok, %{owner_id: ^user_id}} -> true
      _ -> false
    end
  end
end
