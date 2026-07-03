defmodule Magus.Agents.Telemetry do
  @moduledoc """
  Thin `:telemetry.execute/3` wrappers for AgentRun lifecycle points and
  inbox-event wake decisions.

  These are best-effort observability emissions alongside (not instead of)
  the `AutonomyTrace` activity log and `Signals` PubSub broadcasts: never
  raises, so a broken or slow telemetry handler can't break the autonomy
  path it's observing.

  Event names and metadata shape are fixed by the phase 3 "never silent"
  plan (`docs/superpowers/plans/2026-07-03-autonomy-phase3-never-silent.md`,
  Global Constraints):

    * `[:magus, :agents, :run, :enqueued | :started | :completed | :failed | :timed_out]`
    * `[:magus, :agents, :wake, :urgent | :skipped]`

  Measurements are always `%{count: 1}`. Metadata ids are stringified so
  handlers get a consistent shape regardless of whether the caller passed a
  struct or a plain map (or raw ids, already strings/nil).
  """

  require Logger

  @run_events [:enqueued, :started, :completed, :failed, :timed_out]
  @wake_events [:urgent, :skipped]

  @doc """
  Emits `[:magus, :agents, :run, event]` for an `AgentRun` lifecycle point.

  `run` may be an `AgentRun` struct or any map/struct exposing `:id`,
  `:source`, `:target_agent_id`, and `:kind`. Missing fields are emitted as
  `nil`. Never raises.
  """
  @spec run_event(:enqueued | :started | :completed | :failed | :timed_out, any()) :: :ok
  def run_event(event, run) when event in @run_events do
    metadata = %{
      source: get_field(run, :source),
      target_agent_id: stringify(get_field(run, :target_agent_id)),
      run_id: stringify(get_field(run, :id)),
      kind: get_field(run, :kind)
    }

    execute([:magus, :agents, :run, event], metadata)
  end

  def run_event(_event, _run), do: :ok

  @doc """
  Emits `[:magus, :agents, :wake, event]` for an inbox-event wake decision.

  `attrs` is a map with at least `:target_agent_id` and `:source`; a
  `:reason` key (e.g. on `:skipped`) is passed through as-is. Never raises.
  """
  @spec wake_event(:urgent | :skipped, map() | nil) :: :ok
  def wake_event(event, attrs) when event in @wake_events do
    attrs = if is_map(attrs), do: attrs, else: %{}

    metadata =
      %{
        target_agent_id: stringify(get_field(attrs, :target_agent_id)),
        source: get_field(attrs, :source)
      }
      |> maybe_put_reason(get_field(attrs, :reason))

    execute([:magus, :agents, :wake, event], metadata)
  end

  def wake_event(_event, _attrs), do: :ok

  defp maybe_put_reason(metadata, nil), do: metadata
  defp maybe_put_reason(metadata, reason), do: Map.put(metadata, :reason, reason)

  defp execute(event_name, metadata) do
    :telemetry.execute(event_name, %{count: 1}, metadata)
    :ok
  rescue
    e ->
      Logger.warning("Telemetry: emit failed (#{inspect(event_name)}): #{Exception.message(e)}")

      :ok
  end

  defp get_field(nil, _key), do: nil

  defp get_field(map, key) when is_map(map) do
    Map.get(map, key)
  rescue
    _ -> nil
  end

  defp get_field(_other, _key), do: nil

  defp stringify(nil), do: nil
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: to_string(value)
end
