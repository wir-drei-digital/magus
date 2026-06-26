defmodule Magus.Brain.Changes.SetExternalContributor do
  @moduledoc """
  Sets `contributor_type: :external_agent` and `contributor_id` from the
  `:external_agent_id` argument. Used by `:create_as_external_agent` actions
  on Block, Page, and Connection (the same change works for all three because
  they share the contributor schema).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_argument(changeset, :external_agent_id) do
      nil ->
        Ash.Changeset.add_error(changeset, field: :external_agent_id, message: "is required")

      token_id when is_binary(token_id) ->
        changeset
        |> Ash.Changeset.force_change_attribute(:contributor_type, :external_agent)
        |> Ash.Changeset.force_change_attribute(:contributor_id, token_id)
    end
  end
end
