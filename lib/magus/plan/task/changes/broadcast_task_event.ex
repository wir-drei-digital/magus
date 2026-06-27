defmodule Magus.Plan.Task.Changes.BroadcastTaskEvent do
  @moduledoc """
  Broadcasts task changes via PubSub so task panes, plan boards, and the brain
  overview update in real time.

  Conversation tasks publish to `tasks:conversation:{conversation_id}`. Plan
  tasks publish to BOTH `tasks:plan:{brain_page_id}` and
  `tasks:brain:{brain_id}` (the brain id is loaded from the page).
  """

  use Ash.Resource.Change

  require Ash.Query
  require Logger

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, task ->
      event_type =
        case changeset.action.type do
          :create -> "task.created"
          :update -> "task.updated"
          _ -> "task.changed"
        end

      Enum.each(topics(task), fn topic ->
        case Magus.Endpoint.broadcast(topic, event_type, %{task: task}) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning("Task broadcast failed (#{topic}): #{inspect(reason)}")
        end
      end)

      {:ok, task}
    end)
  end

  defp topics(%{conversation_id: conversation_id}) when not is_nil(conversation_id),
    do: ["tasks:conversation:#{conversation_id}"]

  defp topics(%{brain_page_id: brain_page_id}) when not is_nil(brain_page_id) do
    # Select only `brain_id` to avoid hydrating the page's large body/frontmatter.
    page =
      Magus.Brain.Page
      |> Ash.Query.filter(id == ^brain_page_id)
      |> Ash.Query.select([:brain_id])
      |> Ash.read_one(authorize?: false)

    case page do
      {:ok, %{brain_id: brain_id}} ->
        ["tasks:plan:#{brain_page_id}", "tasks:brain:#{brain_id}"]

      _ ->
        ["tasks:plan:#{brain_page_id}"]
    end
  end

  defp topics(_), do: []
end
