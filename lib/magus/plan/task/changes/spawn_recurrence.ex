defmodule Magus.Plan.Task.Changes.SpawnRecurrence do
  @moduledoc """
  After a task is marked as done, spawns the next occurrence if the task
  has a recurrence pattern and a due date. Respects the assigned user's
  timezone so recurring times stay consistent across DST transitions.
  """

  use Ash.Resource.Change
  require Logger

  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.after_action(changeset, fn changeset, task ->
      # Plan tasks (no conversation_id) do not spawn recurrences. `create_task`
      # targets the conversation `:create` action, which requires a non-nil
      # conversation_id; spawning here would error inside the completing task's
      # after_action and could roll back a legitimate completion. Recurrence for
      # plan tasks is a later-plan concern.
      with false <- is_nil(task.conversation_id),
           true <- Ash.Changeset.changing_attribute?(changeset, :status),
           true <- task.status == :done,
           %{} = recurrence when recurrence != %{} <- task.recurrence,
           %DateTime{} <- task.due_at do
        spawn_next(task)
      end

      {:ok, task}
    end)
  end

  defp spawn_next(task) do
    timezone = resolve_timezone(task.assigned_to_user_id)
    next_due = calculate_next_due(task.due_at, normalize_recurrence(task.recurrence), timezone)

    attrs = %{
      title: task.title,
      description: task.description,
      due_at: next_due,
      recurrence: task.recurrence,
      status: :open,
      assigned_to_user_id: task.assigned_to_user_id,
      assigned_to_agent: task.assigned_to_agent,
      assigned_to_custom_agent_id: task.assigned_to_custom_agent_id,
      assigned_by_custom_agent_id: task.assigned_by_custom_agent_id,
      parent_id: task.parent_id,
      metadata: task.metadata
    }

    case Magus.Plan.create_task(task.conversation_id, attrs, authorize?: false) do
      {:ok, new_task} ->
        Logger.debug("Spawned recurring task #{new_task.id} from #{task.id}")

      {:error, error} ->
        Logger.error("Failed to spawn recurring task from #{task.id}: #{inspect(error)}")
    end
  rescue
    e ->
      Logger.error("Exception spawning recurring task from #{task.id}: #{Exception.message(e)}")
  end

  # Convert UTC due_at to user's local time, shift by recurrence, convert back to UTC.
  # This keeps "daily at 9am local" stable across DST transitions.
  defp calculate_next_due(due_at_utc, %{frequency: frequency} = recurrence, timezone) do
    interval = Map.get(recurrence, :interval, 1)
    shift = recurrence_shift(normalize_frequency(frequency), interval)

    case DateTime.shift_zone(due_at_utc, timezone) do
      {:ok, local} ->
        shifted = local |> DateTime.to_naive() |> NaiveDateTime.shift(shift)
        naive_to_utc(shifted, timezone)

      {:error, _} ->
        # Timezone not found (tzdata not configured), fall back to UTC arithmetic
        due_at_utc
        |> DateTime.to_naive()
        |> NaiveDateTime.shift(shift)
        |> DateTime.from_naive!("Etc/UTC")
    end
  end

  # Handle DST gaps (spring-forward) and ambiguous times (fall-back)
  defp naive_to_utc(naive, timezone) do
    case DateTime.from_naive(naive, timezone) do
      {:ok, dt} -> DateTime.shift_zone!(dt, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC")
      {:gap, _just_before, just_after} -> DateTime.shift_zone!(just_after, "Etc/UTC")
    end
  end

  defp recurrence_shift(:daily, interval), do: [day: interval]
  defp recurrence_shift(:weekly, interval), do: [day: interval * 7]
  defp recurrence_shift(:monthly, interval), do: [month: interval]

  defp resolve_timezone(nil), do: "Etc/UTC"

  defp resolve_timezone(user_id) do
    case Ash.get(Magus.Accounts.User, user_id, authorize?: false) do
      {:ok, user} -> user.timezone || "Etc/UTC"
      _ -> "Etc/UTC"
    end
  end

  # Normalize string keys/values from LLM JSON to atom keys
  @known_keys %{
    "frequency" => :frequency,
    "interval" => :interval,
    "days" => :days,
    "day" => :day
  }

  defp normalize_recurrence(recurrence) do
    Map.new(recurrence, fn {k, v} -> {to_atom_key(k), v} end)
  end

  defp to_atom_key(k) when is_atom(k), do: k
  defp to_atom_key(k) when is_binary(k), do: Map.get(@known_keys, k, k)

  defp normalize_frequency(:daily), do: :daily
  defp normalize_frequency(:weekly), do: :weekly
  defp normalize_frequency(:monthly), do: :monthly
  defp normalize_frequency("daily"), do: :daily
  defp normalize_frequency("weekly"), do: :weekly
  defp normalize_frequency("monthly"), do: :monthly
  defp normalize_frequency(_), do: :daily
end
