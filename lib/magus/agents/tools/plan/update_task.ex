defmodule Magus.Agents.Tools.Plan.UpdateTask do
  @moduledoc """
  Jido tool for updating one or several tasks in the conversation's task list.
  """

  use Jido.Action,
    name: "update_task",
    description: """
    Update an existing task, or update several at once.

    **Single task:** pass `task_id` plus the fields to change.
    **Multiple tasks (preferred when changing several):** pass an `updates` array, each item a
    `{task_id, ...fields}` object:
      updates: [{"task_id": "abc", "status": "done"}, {"task_id": "def", "status": "in_progress"}]

    Every update item needs a `task_id`. Changeable fields: title, description, status, position,
    assigned_to, parent_id, due_at. Status values: "open", "in_progress", "done", "cancelled".
    When you complete a task, set status to "done". To assign to the user, set assigned_to to "user".

    To CREATE new tasks use `create_task` instead; `update_task` only changes tasks that already exist.
    """,
    schema: [
      task_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Task ID to update (single update)"
      ],
      updates: [
        type: {:or, [{:list, :map}, nil]},
        default: nil,
        doc:
          "Update several tasks at once: a list of {task_id, ...fields}. Each item needs a task_id plus the fields to change."
      ],
      title: [type: {:or, [:string, nil]}, default: nil, doc: "New title"],
      description: [type: {:or, [:string, nil]}, default: nil, doc: "New description"],
      status: [type: {:or, [:string, nil]}, default: nil, doc: "New status"],
      assigned_to: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "'user' or 'agent'"
      ],
      position: [type: {:or, [:integer, nil]}, default: nil, doc: "New position"],
      parent_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Move to parent (or null for top-level)"
      ],
      due_at: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Due date as ISO8601 datetime string"
      ],
      recurrence: [
        type: {:or, [:map, nil]},
        default: nil,
        doc: "Recurrence pattern: %{frequency: daily|weekly|monthly, interval: 1}"
      ]
    ]

  require Logger

  alias Magus.Agents.Signals

  import Magus.Agents.Tools.Helpers,
    only: [
      get_param: 2,
      validate_context: 2,
      nilify_blank_params: 2,
      ai_actor: 0,
      extract_error_message: 1
    ]

  def display_name, do: "Updating task..."

  def summarize_output(%{updated: updated}) when is_list(updated),
    do: "Updated #{length(updated)} tasks"

  def summarize_output(%{title: title, status: status}), do: "Updated: #{title} (#{status})"
  def summarize_output(%{title: title}), do: "Updated: #{title}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Updated"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        params = nilify_blank_params(params, [:task_id, :parent_id, :title])

        # LLMs reach for a batch when told to change several tasks; accept an
        # `updates` array (also tolerate `tasks`, the name create_task uses) so
        # "update multiple at once" is a first-class op instead of a failed
        # improvisation.
        case parse_updates_param(get_param(params, :updates) || get_param(params, :tasks)) do
          updates when is_list(updates) and updates != [] ->
            Signals.emit_tool_progress(context, :updating, %{count: length(updates)})
            batch_update(updates, ctx)

          _ ->
            task_id = get_param(params, :task_id)
            Signals.emit_tool_progress(context, :updating, %{task_id: task_id})
            single_update(task_id, params, ctx)
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp single_update(nil, _params, _ctx) do
    {:ok,
     %{
       error:
         "task_id is required. To update several tasks at once, pass `updates`: a list of {task_id, ...fields}."
     }}
  end

  defp single_update(task_id, params, ctx) do
    case do_update(task_id, params, ctx) do
      {:ok, updated} ->
        Logger.debug("UpdateTask: updated", id: updated.id, status: updated.status)

        {:ok,
         %{
           task_id: updated.id,
           title: updated.title,
           status: updated.status,
           assigned_to: assigned_to_label(updated),
           completed_by: updated.completed_by
         }}

      {:error, message} ->
        Logger.warning("UpdateTask: failed - #{message}")
        {:ok, %{error: message}}
    end
  end

  defp batch_update(updates, ctx) do
    results = Enum.map(updates, &update_one(&1, ctx))

    updated = for {:ok, row} <- results, do: row
    errors = for {:error, row} <- results, do: row

    payload = %{
      updated: updated,
      message: "Updated #{length(updated)} of #{length(results)} tasks"
    }

    {:ok, if(errors == [], do: payload, else: Map.put(payload, :errors, errors))}
  end

  # One item from an `updates` batch. Each carries its own task_id + fields.
  defp update_one(item, ctx) when is_map(item) do
    item = nilify_blank_params(item, [:task_id, :parent_id, :title])

    case get_param(item, :task_id) do
      nil ->
        {:error, %{error: "Each update needs a task_id"}}

      task_id ->
        case do_update(task_id, item, ctx) do
          {:ok, updated} ->
            {:ok, %{task_id: updated.id, title: updated.title, status: updated.status}}

          {:error, message} ->
            {:error, %{task_id: task_id, error: message}}
        end
    end
  end

  defp update_one(_item, _ctx),
    do: {:error, %{error: "Each update must be an object with a task_id"}}

  # Shared fetch + update path. Returns {:ok, task} | {:error, message} so both
  # single and batch callers format their own payloads.
  defp do_update(task_id, params, ctx) do
    with {:ok, task} <- fetch_task(task_id, ctx),
         attrs = build_attrs(params, ctx),
         {:ok, updated} <- Magus.Plan.update_task(task, attrs, actor: ai_actor()) do
      {:ok, updated}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, error} -> {:error, extract_error_message(error)}
    end
  end

  defp fetch_task(task_id, ctx) do
    case Magus.Plan.get_task(task_id, actor: ai_actor()) do
      {:ok, nil} ->
        {:error, "Task not found"}

      {:ok, task} ->
        if task.conversation_id == ctx.conversation_id do
          {:ok, task}
        else
          {:error, "Task not found in this conversation"}
        end

      {:error, _} ->
        {:error, "Task not found"}
    end
  end

  defp build_attrs(params, ctx) do
    []
    |> maybe_add(:title, get_param(params, :title))
    |> maybe_add(:description, get_param(params, :description))
    |> maybe_add(:status, parse_status(get_param(params, :status)))
    |> maybe_add(:position, get_param(params, :position))
    |> maybe_add(:parent_id, get_param(params, :parent_id))
    |> maybe_add(:due_at, parse_due_at(get_param(params, :due_at)))
    |> maybe_add(:recurrence, get_param(params, :recurrence))
    |> add_assignment(get_param(params, :assigned_to), ctx.user_id)
    |> Map.new()
  end

  defp maybe_add(attrs, _key, nil), do: attrs
  defp maybe_add(attrs, key, value), do: [{key, value} | attrs]

  defp add_assignment(attrs, "user", user_id),
    do: [{:assigned_to_user_id, user_id}, {:assigned_to_agent, nil} | attrs]

  defp add_assignment(attrs, "agent", _user_id),
    do: [{:assigned_to_agent, "assistant"}, {:assigned_to_user_id, nil} | attrs]

  defp add_assignment(attrs, _assigned_to, _user_id), do: attrs

  # LLMs sometimes JSON-encode the updates array as a string instead of a native array.
  defp parse_updates_param(updates) when is_list(updates), do: updates
  defp parse_updates_param(nil), do: nil

  defp parse_updates_param(updates) when is_binary(updates) do
    case Jason.decode(updates) do
      {:ok, list} when is_list(list) -> list
      _ -> nil
    end
  end

  defp parse_updates_param(_), do: nil

  defp parse_due_at(nil), do: nil
  defp parse_due_at(%DateTime{} = dt), do: dt

  defp parse_due_at(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_due_at(_), do: nil

  defp parse_status(nil), do: nil
  defp parse_status(status) when is_atom(status), do: status

  defp parse_status(status) when is_binary(status) do
    String.to_existing_atom(status)
  rescue
    ArgumentError -> nil
  end

  defp assigned_to_label(%{assigned_to_user_id: id}) when not is_nil(id), do: "user"
  defp assigned_to_label(%{assigned_to_agent: agent}) when not is_nil(agent), do: "agent"
  defp assigned_to_label(_), do: nil
end
