defmodule Magus.Agents.Tools.Plan.CreateTask do
  @moduledoc """
  Jido tool for creating tasks in the current conversation's task list.
  Supports both single task and batch creation (ordered).
  """

  use Jido.Action,
    name: "create_task",
    description: """
    Create tasks in the conversation's shared task list (visible to the user in real-time).

    Each task should be a single concrete action, not a category or phase.

    **Single task:** pass `title` directly.
    **Multiple tasks (preferred):** pass a `tasks` array to create them in order:
      tasks: [{"title": "Find papers"}, {"title": "Summarize findings"}, {"title": "Draft report", "assigned_to": "user"}]

    Each item in `tasks` must have a `title`. Optional: `description`, `assigned_to` ("user" or "agent").
    Use `parent_id` to create subtasks under an existing task (one level of nesting).

    Pass `clear_previous: true` to archive all existing tasks in the conversation before creating new ones.
    Use this to start a fresh batch when the old tasks are no longer relevant or the previous plan is complete.

    **Brain page tasks:** pass `brain_page_id` (a page id, or an exact page title; add `brain_id`
    if the title is ambiguous across brains) to put the task(s) on that page's task board instead
    of the conversation. The board is what the user sees on the brain page.
    """,
    schema: [
      title: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Task title (for single task creation)"
      ],
      brain_page_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "Create the task(s) on this brain page's task board instead of the conversation. Accepts a page id or an exact page title."
      ],
      brain_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Brain to resolve a brain_page_id TITLE in (id, slug, or brain title)"
      ],
      tasks: [
        type: {:or, [{:list, :map}, nil]},
        default: nil,
        doc:
          "List of tasks to create in order. Each: {title, description?, assigned_to?, parent_id?}"
      ],
      clear_previous: [
        type: :boolean,
        default: false,
        doc:
          "Archive all existing tasks in the conversation before creating new ones (fresh batch)"
      ],
      description: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Optional longer description"
      ],
      parent_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Parent task ID to create as subtask"
      ],
      status: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Initial status: open, in_progress, done, cancelled"
      ],
      assigned_to: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "'user' to assign to the user"
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
  alias Magus.Agents.Tools.Brain.BrainResolver

  import Magus.Agents.Tools.Helpers,
    only: [
      get_param: 2,
      get_context_value: 2,
      validate_context: 2,
      nilify_blank_params: 2,
      ai_actor: 0,
      extract_error_message: 1
    ]

  def display_name, do: "Creating task..."

  def summarize_output(%{created: created}) when is_list(created),
    do: "Created #{length(created)} tasks"

  def summarize_output(%{title: title}), do: "Created: #{title}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Created"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id]) do
      {:ok, ctx} ->
        params = nilify_blank_params(params, [:brain_page_id, :brain_id, :parent_id])

        case resolve_target(params, ctx, context) do
          {:ok, target} ->
            note = maybe_clear_previous(params, ctx, context, target)

            result =
              case parse_tasks_param(get_param(params, :tasks)) do
                tasks when is_list(tasks) and tasks != [] ->
                  Signals.emit_tool_progress(context, :creating, %{count: length(tasks)})
                  create_batch(tasks, ctx, context, target)

                _ ->
                  Signals.emit_tool_progress(context, :creating, %{
                    title: get_param(params, :title)
                  })

                  create_single(params, ctx, context, target)
              end

            with {:ok, payload} <- result do
              {:ok, if(note, do: Map.put(payload, :note, note), else: payload)}
            end

          {:error, message} ->
            {:ok, %{error: message}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  # Where the task(s) live: the conversation list (default) or a brain page's
  # task board. Page refs resolve through the brain tools' resolver with the
  # REAL user as actor (access-gated); the create itself is then policy-gated
  # too (ActorCanAccessTaskPage, editor) — the ai_actor bypass must never be
  # the thing granting page access.
  defp resolve_target(params, _ctx, context) do
    case get_param(params, :brain_page_id) do
      nil ->
        {:ok, :conversation}

      ref ->
        user = get_context_value(context, :user)

        if is_nil(user) do
          {:error,
           "brain_page_id requires user context. Create the task without brain_page_id instead."}
        else
          page_params =
            case Ecto.UUID.cast(ref) do
              {:ok, _} -> %{"page_id" => ref}
              :error -> %{"page_title" => ref}
            end

          with {:ok, brain_id} <- BrainResolver.resolve_brain_id(context, params),
               {:ok, page} <- BrainResolver.resolve_page(context, page_params, brain_id) do
            {:ok, {:page, page, user}}
          else
            {:error, msg} when is_binary(msg) -> {:error, msg}
            {:error, err} -> {:error, extract_error_message(err)}
          end
        end
    end
  end

  defp maybe_clear_previous(params, ctx, context, target) do
    cond do
      get_param(params, :clear_previous) != true ->
        nil

      target != :conversation ->
        # archive_all_tasks is conversation-keyed; silently archiving a page
        # board the user curates would be destructive. Say so instead.
        "clear_previous was ignored: it archives conversation tasks only, not the page's task board."

      true ->
        Signals.emit_tool_progress(context, :clearing_previous, %{})

        Magus.Plan.archive_all_tasks(
          ctx.conversation_id,
          actor: Magus.Agents.Tools.Helpers.ai_actor()
        )

        nil
    end
  end

  defp create_batch(tasks, ctx, _context, target) do
    # Normalize: ensure each item is a string-keyed map with at least "title"
    tasks =
      Enum.map(tasks, fn item ->
        item
        |> Enum.map(fn {k, v} -> {to_string(k), v} end)
        |> Map.new()
      end)

    # Validate all items have titles
    missing_title = Enum.find_index(tasks, fn item -> !item["title"] || item["title"] == "" end)

    if missing_title do
      {:ok,
       %{
         error:
           "Task at position #{missing_title + 1} is missing a title. Each task needs: {\"title\": \"...\"}"
       }}
    else
      results =
        Enum.reduce_while(tasks, [], fn task_params, acc ->
          attrs = build_attrs(task_params, ctx)

          case create_on_target(target, attrs, ctx) do
            {:ok, task} ->
              {:cont, [%{task_id: task.id, title: task.title, position: task.position} | acc]}

            {:error, error} ->
              {:halt, {:error, extract_error_message(error)}}
          end
        end)

      case results do
        {:error, message} ->
          {:ok, %{error: message}}

        created ->
          created = Enum.reverse(created)

          {:ok,
           %{created: created, message: "Created #{length(created)} tasks in order"}
           |> put_target_info(target)}
      end
    end
  end

  defp create_single(params, ctx, _context, target) do
    attrs = build_attrs(params, ctx)

    case create_on_target(target, attrs, ctx) do
      {:ok, task} ->
        Logger.debug("CreateTask: created", id: task.id, title: task.title)

        {:ok,
         %{
           task_id: task.id,
           title: task.title,
           status: task.status,
           parent_id: task.parent_id,
           position: task.position,
           assigned_to: assigned_to_label(task)
         }
         |> put_target_info(target)}

      {:error, error} ->
        message = extract_error_message(error)
        Logger.warning("CreateTask: failed - #{message}")
        {:ok, %{error: message}}
    end
  end

  # Conversation tasks keep the ai_actor (the agent's own plan list, policies
  # bypass for AI). Page tasks are created AS THE USER so the editor-level
  # ActorCanAccessTaskPage policy actually gates them. create_plan does not
  # accept :recurrence — drop it rather than erroring the whole create.
  defp create_on_target(:conversation, attrs, ctx) do
    Magus.Plan.create_task(ctx.conversation_id, attrs, actor: ai_actor())
  end

  defp create_on_target({:page, page, user}, attrs, _ctx) do
    Magus.Plan.create_plan_task(page.id, Map.drop(attrs, [:recurrence]), actor: user)
  end

  defp put_target_info(payload, :conversation), do: payload

  defp put_target_info(payload, {:page, page, _user}) do
    payload
    |> Map.put(:brain_page_id, page.id)
    |> Map.put(:page_title, page.title)
  end

  # LLMs sometimes JSON-encode the tasks array as a string instead of passing a native array
  defp parse_tasks_param(tasks) when is_list(tasks), do: tasks
  defp parse_tasks_param(nil), do: nil

  defp parse_tasks_param(tasks) when is_binary(tasks) do
    case Jason.decode(tasks) do
      {:ok, list} when is_list(list) -> list
      _ -> nil
    end
  end

  defp parse_tasks_param(_), do: nil

  defp build_attrs(params, ctx) do
    title = get_param(params, :title) || params["title"]
    description = get_param(params, :description) || params["description"]
    parent_id = get_param(params, :parent_id) || params["parent_id"]
    status = parse_status(get_param(params, :status) || params["status"])
    assigned_to = get_param(params, :assigned_to) || params["assigned_to"]
    due_at = parse_due_at(get_param(params, :due_at) || params["due_at"])
    recurrence = get_param(params, :recurrence) || params["recurrence"]

    %{title: title}
    |> maybe_put(:description, description)
    |> maybe_put(:parent_id, parent_id)
    |> maybe_put(:status, status)
    |> maybe_put(:due_at, due_at)
    |> maybe_put(:recurrence, recurrence)
    |> put_assignment(assigned_to, ctx.user_id)
  end

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

  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp put_assignment(attrs, "user", user_id) do
    attrs
    |> Map.put(:assigned_to_user_id, user_id)
    |> Map.put(:assigned_to_agent, nil)
  end

  defp put_assignment(attrs, "agent", _user_id) do
    Map.put(attrs, :assigned_to_agent, "assistant")
  end

  defp put_assignment(attrs, _assigned_to, _user_id), do: attrs

  defp assigned_to_label(%{assigned_to_user_id: id}) when not is_nil(id), do: "user"
  defp assigned_to_label(%{assigned_to_agent: agent}) when not is_nil(agent), do: "agent"
  defp assigned_to_label(_), do: nil
end
