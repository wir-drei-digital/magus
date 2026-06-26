defmodule Magus.Agents.Tools.Autonomy.SetNextWakeup do
  @moduledoc """
  Sets the absolute datetime at which the agent should next wake up.
  Overrides the default heartbeat interval. If unused during a run,
  the completion plugin falls back to the default interval.

  The reason is preserved on the tool event message in the agent's
  home conversation, accessible from the conversation timeline.
  """
  use Jido.Action,
    name: "set_next_wakeup",
    description:
      "Schedule your next autonomous wake-up at a specific UTC timestamp. Use ISO8601. Provide a reason.",
    schema: [
      at: [
        type: :string,
        required: true,
        doc: "ISO8601 UTC timestamp (e.g. 2026-04-25T18:30:00Z)"
      ],
      reason: [type: :string, required: true, doc: "Why this wakeup time was chosen"]
    ]

  alias Magus.Agents.Tools.Helpers

  import Magus.Agents.Tools.Helpers,
    only: [validate_context: 2, ai_actor: 0, get_param: 2]

  def display_name, do: "Scheduling next wake-up..."

  def summarize_output(%{status: "scheduled", next_scheduled_at: at}),
    do: "Scheduled for #{DateTime.to_iso8601(at)}"

  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    with {:ok, ctx} <- validate_context(context, [:user_id, :custom_agent_id]),
         {:ok, at} <- parse_timestamp(get_param(params, :at)),
         :ok <- check_in_future(at) do
      actor = ai_actor()
      agent = Ash.get!(Magus.Agents.CustomAgent, ctx.custom_agent_id, actor: actor)

      case Magus.Agents.set_custom_agent_next_scheduled_at(agent, at, actor: actor) do
        {:ok, _} ->
          {:ok,
           %{
             status: "scheduled",
             next_scheduled_at: at,
             reason: get_param(params, :reason)
           }}

        {:error, error} ->
          {:ok, %{error: Helpers.extract_error_message(error)}}
      end
    else
      {:error, message} -> {:ok, %{error: message}}
    end
  end

  defp parse_timestamp(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _offset} -> {:ok, DateTime.shift_zone!(dt, "Etc/UTC")}
      _ -> {:error, "Invalid ISO8601 timestamp: #{s}"}
    end
  end

  defp check_in_future(at) do
    if DateTime.compare(at, DateTime.utc_now()) == :gt do
      :ok
    else
      {:error, "next wake-up must be in the future"}
    end
  end
end
