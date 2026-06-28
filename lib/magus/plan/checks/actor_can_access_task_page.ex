defmodule Magus.Plan.Checks.ActorCanAccessTaskPage do
  @moduledoc """
  Authorizes plan-task access by delegating to the page's own Brain policies.

  Reads the page id from either the `:brain_page_id` action argument (create /
  plan-scoped reads) or the changeset/record attribute (update / destroy), loads
  the page with `authorize?: false`, then asks `Ash.can?` whether the actor may
  run the gating page action (`:read` for viewers, `:update_body` for editors).

  When `field: :brain_id` (the brain-level `:for_brain` rollup read), the brain
  id is read from the query argument and authorization is delegated to the
  brain's own `:read` policy via `Ash.can?`: same viewer semantics as the rest
  of the system, but strict (a non-member is forbidden, not filtered to empty).

  Options:
    * `:min_role`: `:viewer` (default) or `:editor`
    * `:field`: argument/attribute holding the id (default `:brain_page_id`;
      use `:brain_id` for the brain-level rollup read)
  """

  use Ash.Policy.SimpleCheck

  alias Magus.Checks.Helpers

  @impl true
  def describe(opts) do
    target = if Keyword.get(opts, :field) == :brain_id, do: "brain", else: "task's plan page"
    "actor can #{role_word(opts)} the #{target}"
  end

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    field = Keyword.get(opts, :field, :brain_page_id)
    min_role = Keyword.get(opts, :min_role, :viewer)

    case field do
      :brain_id ->
        case Helpers.value_from_context(context, :brain_id) do
          nil -> false
          brain_id -> can_access_brain?(actor, brain_id, min_role)
        end

      _ ->
        with value when not is_nil(value) <- Helpers.value_from_context(context, field),
             {:ok, page_id} <- page_id_for(field, value) do
          can_access?(actor, page_id, min_role)
        else
          _ -> false
        end
    end
  end

  defp page_id_for(:brain_page_id, page_id), do: {:ok, page_id}

  defp page_id_for(_task_field, task_id) do
    case Ash.get(Magus.Plan.Task, task_id, authorize?: false) do
      {:ok, %{brain_page_id: page_id}} when not is_nil(page_id) -> {:ok, page_id}
      _ -> :error
    end
  end

  defp can_access?(actor, page_id, min_role) do
    case Ash.get(Magus.Brain.Page, page_id, authorize?: false) do
      {:ok, page} -> Ash.can?({page, page_action(min_role)}, actor)
      _ -> false
    end
  end

  defp can_access_brain?(actor, brain_id, min_role) do
    case Ash.get(Magus.Brain.BrainResource, brain_id, authorize?: false) do
      {:ok, brain} -> Ash.can?({brain, brain_action(min_role)}, actor)
      _ -> false
    end
  end

  # The brain's own policies gate `:read` (viewer) and `:update` (editor+).
  defp brain_action(:editor), do: :update
  defp brain_action(_), do: :read

  defp page_action(:editor), do: :update_body
  defp page_action(_), do: :read

  defp role_word(opts), do: if(Keyword.get(opts, :min_role) == :editor, do: "write", else: "read")
end
