defmodule Magus.Agents.HeartbeatEventMessage do
  @moduledoc """
  Helper for creating and updating the visible `:event` message that
  represents a heartbeat or manual wake-up in the home conversation.

  Mirrors the jobs pattern: one message per wake-up run, transitioning
  through `:running` to a terminal state (`:complete`, `:skipped`,
  `:failed`).

  Metadata shape:

      %{
        "wakeup_run_id" => <agent_run_id>,
        "wakeup_stage" => :running | :complete | :skipped | :failed,
        "source" => :heartbeat | :manual_trigger | :inbox_urgent
      }

  The `wakeup_run_id` lets UIs link the visible event message back to
  the underlying `Magus.Agents.AgentRun` for full detail. When a wake-up
  is skipped before a run is created (e.g. budget gate), `:run_id` may be
  passed as `nil` and the `wakeup_run_id` key is omitted from metadata
  rather than carrying a fake id.
  """

  @running_text %{
    heartbeat: "Heartbeat started at {time}",
    manual_trigger: "Manual wake-up triggered by {user_label}",
    inbox_urgent: "Woken by urgent inbox event at {time}"
  }

  @doc """
  Create a new `:event` message in the given home conversation for a
  wake-up run that is starting now.

  ## Required opts

    * `:run_id` — the `AgentRun` id (recorded in metadata so the UI can
      link back to the run). Pass `nil` when no run was created (skip
      events emitted before enqueue), in which case the `wakeup_run_id`
      key is omitted from metadata.
    * `:source` — `:heartbeat`, `:manual_trigger`, or `:inbox_urgent`.

  ## Optional opts

    * `:user_label` — string label used in the manual-trigger text
      (default: `"user"`). Ignored for `:heartbeat`.
  """
  def create(conversation_id, opts) when is_list(opts) do
    source = Keyword.fetch!(opts, :source)
    run_id = Keyword.fetch!(opts, :run_id)
    user_label = Keyword.get(opts, :user_label, "user")
    time = DateTime.utc_now() |> DateTime.to_iso8601()

    text =
      @running_text
      |> Map.fetch!(source)
      |> String.replace("{time}", time)
      |> String.replace("{user_label}", user_label)

    metadata =
      %{
        "wakeup_stage" => "running",
        "source" => to_string(source)
      }
      |> maybe_put_run_id(run_id)

    Magus.Chat.create_event_message(
      text,
      conversation_id,
      %{metadata: metadata},
      authorize?: false
    )
  end

  defp maybe_put_run_id(metadata, nil), do: metadata
  defp maybe_put_run_id(metadata, run_id), do: Map.put(metadata, "wakeup_run_id", run_id)

  @doc """
  Transition the wake-up event message to a terminal state.

  Updates the visible `text` and merges a new `wakeup_stage` value into
  the existing `metadata`, preserving `wakeup_run_id`/`source` and any
  other fields a caller stored.

  Supported stages:

    * `:complete` — data: `%{dismissed: integer, next_at: DateTime.t() | nil}`
    * `:skipped_in_flight` — data ignored
    * `:skipped_budget` — data: `%{used: integer, limit: integer}`
    * `:skipped_spend_budget` — data ignored
    * `:failed` — data: `%{error: String.t()}`
  """
  def transition(message, stage, data \\ %{})

  def transition(message, :complete, data) do
    dismissed = Map.get(data, :dismissed, 0)
    next_at = Map.get(data, :next_at)
    next_str = if next_at, do: DateTime.to_iso8601(next_at), else: "default interval"
    text = "Heartbeat completed: dismissed #{dismissed} event(s); next at #{next_str}"
    update_text(message, text, "complete")
  end

  def transition(message, :skipped_in_flight, _data) do
    update_text(
      message,
      "Heartbeat skipped: previous wake-up still running",
      "skipped"
    )
  end

  def transition(message, :skipped_budget, %{used: used, limit: limit}) do
    update_text(
      message,
      "Heartbeat skipped: daily run cap reached (#{used}/#{limit})",
      "skipped"
    )
  end

  def transition(message, :skipped_spend_budget, _data) do
    update_text(
      message,
      "Heartbeat skipped: insufficient spend budget",
      "skipped"
    )
  end

  def transition(message, :failed, %{error: error}) do
    update_text(message, "Heartbeat failed: #{error}", "failed")
  end

  defp update_text(message, text, stage) do
    new_metadata =
      (message.metadata || %{})
      |> Map.put("wakeup_stage", stage)

    Magus.Chat.update_event_message(
      message,
      %{text: text, metadata: new_metadata},
      authorize?: false
    )
  end
end
