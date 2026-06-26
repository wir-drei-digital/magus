defmodule Magus.Agents.Tools.Autonomy.SetNextWakeupTest do
  use Magus.DataCase, async: true
  import Magus.Generators

  alias Magus.Agents.Tools.Autonomy.SetNextWakeup

  test "sets next_scheduled_at when given an ISO8601 timestamp" do
    user = generate(user())
    agent = custom_agent(user, %{})
    target = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

    {:ok, result} =
      SetNextWakeup.run(
        %{at: DateTime.to_iso8601(target), reason: "Quiet hours"},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    assert result.status == "scheduled"

    reloaded = Magus.Agents.get_custom_agent!(agent.id, actor: user)
    assert DateTime.compare(reloaded.next_scheduled_at, target) in [:eq, :gt]
  end

  test "normalizes non-UTC offsets to UTC before persisting" do
    user = generate(user())
    agent = custom_agent(user, %{})

    # 2030-01-01T12:00:00+02:00 == 2030-01-01T10:00:00Z
    iso_with_offset = "2030-01-01T12:00:00+02:00"
    expected_utc = ~U[2030-01-01 10:00:00Z]

    {:ok, result} =
      SetNextWakeup.run(
        %{at: iso_with_offset, reason: "Quiet hours"},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    assert result.status == "scheduled"
    assert result.next_scheduled_at.time_zone == "Etc/UTC"
    assert DateTime.compare(result.next_scheduled_at, expected_utc) == :eq

    reloaded = Magus.Agents.get_custom_agent!(agent.id, actor: user)
    assert reloaded.next_scheduled_at.time_zone == "Etc/UTC"
    assert DateTime.compare(reloaded.next_scheduled_at, expected_utc) == :eq
  end

  test "rejects timestamps in the past" do
    user = generate(user())
    agent = custom_agent(user, %{})
    past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.to_iso8601()

    {:ok, %{error: msg}} =
      SetNextWakeup.run(
        %{at: past, reason: "x"},
        %{user_id: user.id, custom_agent_id: agent.id}
      )

    assert msg =~ "past" or msg =~ "future"
  end

  test "rejects malformed timestamp" do
    user = generate(user())
    agent = custom_agent(user, %{})

    {:ok, %{error: _}} =
      SetNextWakeup.run(
        %{at: "not a date", reason: "x"},
        %{user_id: user.id, custom_agent_id: agent.id}
      )
  end

  test "errors when context is missing" do
    {:ok, %{error: msg}} =
      SetNextWakeup.run(
        %{at: "2030-01-01T00:00:00Z", reason: "x"},
        %{}
      )

    assert msg =~ "Missing"
  end
end
