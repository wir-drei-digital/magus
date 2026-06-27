defmodule Magus.Plan.Task.Changes.RecordTaskEvent do
  @moduledoc """
  Records a `Plan.TaskEvent` after a task action succeeds. Only writes for plan
  tasks (those with a `brain_page_id`); conversation tasks are skipped. The
  actor label is the agent label or the user's email, best-effort.

  Option: `:kind` is the event kind. For `:status_changed`, the new status is
  added to metadata and a done status upgrades the kind to `:completed`. For
  `:claimed`, the claiming label is captured.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, context) do
    kind = Keyword.fetch!(opts, :kind)

    Ash.Changeset.after_action(changeset, fn _cs, task ->
      if is_nil(task.brain_page_id) do
        {:ok, task}
      else
        Magus.Plan.TaskEvent
        |> Ash.Changeset.for_create(
          :create,
          %{
            task_id: task.id,
            brain_page_id: task.brain_page_id,
            kind: resolve_kind(kind, changeset, task),
            actor_label: actor_label(opts, task, context),
            metadata: metadata(kind, task)
          },
          authorize?: false
        )
        |> Ash.create!()

        {:ok, task}
      end
    end)
  end

  defp resolve_kind(:status_changed, _changeset, %{status: :done}), do: :completed
  defp resolve_kind(kind, _changeset, _task), do: kind

  defp metadata(:status_changed, %{status: status}), do: %{"status" => to_string(status)}
  defp metadata(_kind, _task), do: %{}

  # An explicit option wins (e.g. the lease reaper labels itself); otherwise fall
  # back to the agent label or the acting user's email.
  defp actor_label(opts, task, context) do
    case Keyword.get(opts, :actor_label) do
      label when is_binary(label) -> label
      _ -> default_actor_label(task, context)
    end
  end

  defp default_actor_label(%{assigned_to_agent: agent}, _context) when is_binary(agent), do: agent

  defp default_actor_label(_task, %{actor: %Magus.Accounts.User{email: email}}),
    do: to_string(email)

  defp default_actor_label(_task, _context), do: nil
end
