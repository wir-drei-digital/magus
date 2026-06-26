defmodule Magus.Agents.Tools.Tasks.SpawnTask do
  use Jido.Action,
    name: "spawn_task",
    description: """
    Spawn a background task conversation that runs autonomously and reports back.

    Use this when the user asks you to monitor something, do periodic research,
    or any work that should happen in the background over time.

    The task gets its own conversation and runs on a schedule (cron or one-time delay).
    It will report progress back to this conversation and notify the user when done.
    """,
    schema: [
      objective: [
        type: :string,
        required: true,
        doc: "Clear description of what the task should accomplish"
      ],
      schedule: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "Cron expression for recurring execution (e.g., '0 */2 * * *' for every 2 hours). If nil, runs once after delay_minutes."
      ],
      delay_minutes: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "Minutes to wait before first/only execution. Defaults to 1 if no schedule given."
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, get_param: 2, ai_actor: 0, extract_error_message: 1]

  @max_task_conversations 10

  def display_name, do: "Spawning task..."

  def summarize_output(%{task_conversation_id: _}), do: "Task started"
  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id, :user_id, :user]) do
      {:ok, ctx} -> spawn_task(params, ctx, context)
      {:error, message} -> {:ok, %{error: message}}
    end
  end

  defp spawn_task(params, ctx, full_context) do
    objective = get_param(params, :objective)
    schedule = get_param(params, :schedule)
    delay_minutes = get_param(params, :delay_minutes)

    with :ok <- check_task_limit(ctx.user_id),
         {:ok, child} <- create_task_conversation(objective, ctx, full_context),
         {:ok, job} <- create_task_job(child, objective, schedule, delay_minutes, ctx) do
      Magus.Chat.create_event_message(
        "Task started: #{String.slice(objective, 0, 200)}",
        ctx.conversation_id,
        authorize?: false
      )

      {:ok,
       %{
         task_conversation_id: child.id,
         objective: objective,
         schedule_type: to_string(job.schedule_type),
         status: "spawned"
       }}
    else
      {:error, :task_limit_reached} ->
        {:ok,
         %{error: "You have reached the maximum of #{@max_task_conversations} concurrent tasks."}}

      {:error, error} ->
        {:ok, %{error: extract_error_message(error)}}
    end
  end

  defp check_task_limit(user_id) do
    require Ash.Query

    count =
      Magus.Chat.Conversation
      |> Ash.Query.filter(user_id == ^user_id and is_task_conversation == true)
      |> Ash.count!(authorize?: false)

    if count >= @max_task_conversations, do: {:error, :task_limit_reached}, else: :ok
  end

  defp create_task_conversation(objective, ctx, full_context) do
    system_prompt = """
    You are running as a background task. Your objective:

    #{objective}

    IMPORTANT RULES:
    - Use `report_to_parent` to send progress updates to the user.
    - Use `complete_task` when your objective is fulfilled or you cannot make further progress.
    - You have a maximum of 20 iterations. If you reach this limit, call `complete_task` with a summary.
    - Be concise in your reports. The user sees them as notifications.
    """

    attrs = %{
      is_task_conversation: true,
      parent_conversation_id: ctx.conversation_id,
      system_prompt: system_prompt
    }

    # workspace_id is an optional enrichment from the tool context (set by
    # Preflight and ToolBuilder for workspace conversations). Read from the
    # raw full_context because validate_context only captures required keys.
    attrs =
      case Map.get(full_context, :workspace_id) do
        nil -> attrs
        workspace_id -> Map.put(attrs, :workspace_id, workspace_id)
      end

    Magus.Chat.create_conversation(attrs, actor: ctx.user)
  end

  defp create_task_job(child, objective, schedule, delay_minutes, ctx) do
    {schedule_type, schedule_attrs} =
      cond do
        schedule ->
          {:cron,
           %{
             cron_expression: schedule,
             ends_at: DateTime.add(DateTime.utc_now(), 90, :day)
           }}

        delay_minutes ->
          {:one_time,
           %{
             scheduled_at: DateTime.add(DateTime.utc_now(), delay_minutes, :minute)
           }}

        true ->
          {:one_time,
           %{
             scheduled_at: DateTime.add(DateTime.utc_now(), 1, :minute)
           }}
      end

    attrs =
      Map.merge(schedule_attrs, %{
        name: "task_run",
        trigger_prompt: objective,
        schedule_type: schedule_type,
        user_id: ctx.user_id
      })

    Magus.Workflows.create_job(child.id, attrs, actor: ai_actor())
  end
end
