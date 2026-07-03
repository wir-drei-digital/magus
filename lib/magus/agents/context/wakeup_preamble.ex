defmodule Magus.Agents.Context.WakeupPreamble do
  @moduledoc """
  Synthesizes the wakeup system-prompt preamble for autonomous runs
  (source: :heartbeat, :manual_trigger, or :inbox_urgent). Returns ""
  for other sources so it can be called unconditionally.
  """
  require Ash.Query
  require Logger

  @doc """
  Builds the preamble text. Pass a map with:
    * :custom_agent: the CustomAgent struct
    * :source:       :heartbeat | :manual_trigger | :inbox_urgent | :mention | :sub_agent_spawn
    * :user:         the actor (for ash queries / display name)

  Returns the empty string for sources other than `:heartbeat`,
  `:manual_trigger`, and `:inbox_urgent` so callers can invoke this
  unconditionally during context assembly.
  """
  @spec build(map()) :: String.t()
  def build(%{source: source} = ctx)
      when source in [:heartbeat, :manual_trigger, :inbox_urgent] do
    agent = ctx.custom_agent
    user = ctx.user

    """
    #{header(source, user)}

    Current time: #{DateTime.utc_now() |> DateTime.to_iso8601()}
    Default interval: every #{agent.heartbeat_default_interval_minutes} minutes
    Last successful wake-up: #{format_last(agent.id, user)}

    #{inbox_section(agent.id, user)}
    #{tasks_section(agent.id, user)}
    #{recent_activity_section(agent.id, user)}

    You may use these tools in addition to your regular ones:
      - list_inbox_events()    : full pending event list
      - dismiss_event(event_id, reason)   : resolve an event without follow-up
      - link_inbox_event(event_id)        : flag an event you intend to act on
        with your other tools, so it gets resolved when this run completes
        (or unlinked if it fails). Use this instead of dismiss when you're
        going to do real work on the event.
      - set_next_wakeup(at, reason)       : override your next wake-up time (ISO8601 UTC)

    Decide: dismiss noise, do work using your tools, or simply set your
    next wakeup. Be concise; this is autonomous work, not a chat.
    """
  end

  def build(_), do: ""

  defp header(:heartbeat, _user), do: "You are waking up on your scheduled heartbeat."

  defp header(:inbox_urgent, _user), do: "You were woken by an urgent inbox event."

  defp header(:manual_trigger, user) do
    name = Map.get(user || %{}, :display_name) || Map.get(user || %{}, :email) || "user"
    "You were manually triggered by #{name}."
  end

  defp format_last(agent_id, user) do
    case last_wakeup_run(agent_id, user) do
      nil -> "never"
      %{completed_at: at} when not is_nil(at) -> DateTime.to_iso8601(at)
      _ -> "in progress"
    end
  end

  defp last_wakeup_run(agent_id, user) do
    Magus.Agents.AgentRun
    |> Ash.Query.filter(
      target_agent_id == ^agent_id and source in [:heartbeat, :manual_trigger] and
        status == :complete
    )
    |> Ash.Query.sort(completed_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: user)
    |> List.first()
  rescue
    e in [Ash.Error.Unknown, Ash.Error.Forbidden, Ash.Error.Invalid] ->
      Logger.debug("WakeupPreamble.last_wakeup_run failed: #{Exception.message(e)}")
      nil
  end

  defp inbox_section(agent_id, user) do
    pending =
      Magus.Agents.AgentInboxEvent
      |> Ash.Query.filter(agent_id == ^agent_id and status in [:pending, :waiting])
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(50)
      |> Ash.read!(actor: user)

    case pending do
      [] ->
        "Inbox: empty."

      events ->
        recent = Enum.take(events, 3)

        recent_lines =
          Enum.map_join(recent, "\n", fn e ->
            "  - #{e.event_type}: #{e.title}"
          end)

        "Inbox: #{length(events)} pending event(s). Most recent:\n#{recent_lines}"
    end
  rescue
    e in [Ash.Error.Unknown, Ash.Error.Forbidden, Ash.Error.Invalid] ->
      Logger.debug("WakeupPreamble.inbox_section failed: #{Exception.message(e)}")
      "Inbox: (unavailable)"
  end

  defp tasks_section(agent_id, user) do
    open =
      Magus.Plan.Task
      |> Ash.Query.filter(
        assigned_to_custom_agent_id == ^agent_id and status in [:open, :in_progress]
      )
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(5)
      |> Ash.read!(actor: user)

    case open do
      [] ->
        "Open tasks: none."

      tasks ->
        top = Enum.take(tasks, 3)
        lines = Enum.map_join(top, "\n", fn t -> "  - #{t.title}" end)
        "Open tasks: #{length(tasks)}. Top:\n#{lines}"
    end
  rescue
    e in [Ash.Error.Unknown, Ash.Error.Forbidden, Ash.Error.Invalid] ->
      Logger.debug("WakeupPreamble.tasks_section failed: #{Exception.message(e)}")
      "Open tasks: (unavailable)"
  end

  defp recent_activity_section(agent_id, user) do
    case fetch_recent_activity(agent_id, user) do
      [] ->
        "Recent activity: none."

      activities ->
        lines =
          Enum.map_join(activities, "\n", fn a ->
            "  - #{format_activity_time(a)}: #{format_activity_label(a)}"
          end)

        "Recent activity:\n#{lines}"
    end
  end

  defp fetch_recent_activity(agent_id, user) do
    Magus.Agents.AgentActivityLog
    |> Ash.Query.filter(agent_id == ^agent_id)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(5)
    |> Ash.read!(actor: user)
  rescue
    e in [Ash.Error.Unknown, Ash.Error.Forbidden, Ash.Error.Invalid] ->
      Logger.debug("WakeupPreamble.fetch_recent_activity failed: #{Exception.message(e)}")
      []
  end

  defp format_activity_time(%{inserted_at: at}), do: DateTime.to_iso8601(at)
  defp format_activity_label(%{activity_type: t, summary: s}) when is_binary(s), do: "#{t} (#{s})"
  defp format_activity_label(%{activity_type: t}), do: to_string(t)
end
