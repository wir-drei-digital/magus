defmodule Magus.Agents.Tools.Jobs.UpdateJob do
  @moduledoc """
  Tool for modifying an existing job's settings.

  Allows updating the job's name, description, trigger prompt,
  memory association, cron expression, and end date.

  ## Usage with Jido AI

      tools = [Magus.Agents.Tools.Jobs.UpdateJob]
      tool_contexts = %{
        Magus.Agents.Tools.Jobs.UpdateJob => %{
          conversation_id: conversation.id
        }
      }
  """

  use Jido.Action,
    name: "update_job",
    description: "Modify an existing job's settings.",
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "Name of the job to update"
      ],
      new_name: [
        type: :string,
        required: false,
        doc: "New name for the job"
      ],
      description: [
        type: :string,
        required: false,
        doc: "New description"
      ],
      trigger_prompt: [
        type: :string,
        required: false,
        doc: "New trigger prompt"
      ],
      memory_name: [
        type: :string,
        required: false,
        doc: "New memory name to use"
      ],
      cron_expression: [
        type: :string,
        required: false,
        doc: "New cron expression (UTC). Updating this will recalculate next_run_at."
      ],
      starts_at: [
        type: :string,
        required: false,
        doc: "New start date (UTC ISO8601). Updating this will recalculate next_run_at."
      ],
      ends_at: [
        type: :string,
        required: false,
        doc: "New end date (UTC ISO8601)"
      ]
    ]

  require Logger

  import Magus.Agents.Tools.Jobs.Helpers,
    only: [
      validate_context: 2,
      extract_error_message: 1,
      ai_actor: 0,
      parse_datetime: 1,
      format_datetime: 2,
      find_job_by_name: 2,
      get_timezone: 2
    ]

  import Magus.Agents.Tools.Helpers, only: [get_param: 2]

  @doc "User-friendly display name shown in the UI when this tool is executing"
  def display_name, do: "Updating job..."

  @doc "Generate a human-readable summary of the tool output for UI display"
  def summarize_output(%{status: "updated", name: name}), do: "Updated: #{name}"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        name = get_param(params, :name)
        Logger.debug("UpdateJob: executing", name: name)
        update_job(name, params, ctx, context)

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp update_job(name, params, ctx, context) do
    case find_job_by_name(ctx.conversation_id, name) do
      {:ok, job} ->
        update_attrs = build_update_attrs(params)

        case Magus.Workflows.update_job(job, update_attrs, actor: ai_actor()) do
          {:ok, updated} ->
            timezone = get_timezone(context, updated)

            Logger.info("UpdateJob: updated", name: updated.name, id: updated.id)

            {:ok,
             %{
               status: "updated",
               name: updated.name,
               next_run_at: format_datetime(updated.next_run_at, timezone)
             }}

          {:error, error} ->
            message = extract_error_message(error)
            Logger.warning("UpdateJob: failed - #{message}")
            {:ok, %{error: message}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp build_update_attrs(params) do
    %{}
    |> maybe_put(:name, get_param(params, :new_name))
    |> maybe_put(:description, get_param(params, :description))
    |> maybe_put(:trigger_prompt, get_param(params, :trigger_prompt))
    |> maybe_put(:memory_name, get_param(params, :memory_name))
    |> maybe_put(:cron_expression, get_param(params, :cron_expression))
    |> maybe_put(:starts_at, parse_datetime(get_param(params, :starts_at)))
    |> maybe_put(:ends_at, parse_datetime(get_param(params, :ends_at)))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
