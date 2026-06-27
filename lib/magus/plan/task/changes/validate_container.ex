defmodule Magus.Plan.Task.Changes.ValidateContainer do
  @moduledoc """
  Ensures a task has exactly one container set: a conversation OR a brain (plan)
  page. The DB check constraint is the backstop; this returns a friendly error
  before hitting the database.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn cs ->
      conversation_id = Ash.Changeset.get_attribute(cs, :conversation_id)
      brain_page_id = Ash.Changeset.get_attribute(cs, :brain_page_id)

      case {conversation_id, brain_page_id} do
        {nil, nil} ->
          Ash.Changeset.add_error(cs,
            field: :brain_page_id,
            message: "task must belong to a conversation or a plan page"
          )

        {cid, pid} when not is_nil(cid) and not is_nil(pid) ->
          Ash.Changeset.add_error(cs,
            field: :brain_page_id,
            message: "task cannot belong to both a conversation and a plan page"
          )

        _ ->
          cs
      end
    end)
  end
end
