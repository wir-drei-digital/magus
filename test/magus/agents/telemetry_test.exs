defmodule Magus.Agents.TelemetryTest do
  @moduledoc """
  Tests for `Magus.Agents.Telemetry`, thin `:telemetry.execute/3` wrappers
  emitted at AgentRun lifecycle points and inbox-event wake decisions.
  Never raises: telemetry emission must not break the autonomy path it
  observes.
  """

  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.RunOrchestrator
  alias Magus.Agents.Telemetry

  setup do
    user = generate(user())
    source_conversation = generate(conversation(actor: user))

    %{user: user, source_conversation: source_conversation}
  end

  defp attach(events) do
    test_pid = self()
    handler_id = {:telemetry_test, make_ref()}

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    handler_id
  end

  describe "run_event/2" do
    test "emits [:magus, :agents, :run, :enqueued] with expected metadata" do
      attach([[:magus, :agents, :run, :enqueued]])

      run = %{
        id: Ash.UUIDv7.generate(),
        source: :heartbeat,
        target_agent_id: "agent-123",
        kind: :delegate
      }

      assert :ok = Telemetry.run_event(:enqueued, run)

      assert_receive {:telemetry_event, [:magus, :agents, :run, :enqueued], measurements,
                      metadata}

      assert measurements == %{count: 1}
      assert metadata.source == :heartbeat
      assert metadata.target_agent_id == "agent-123"
      assert metadata.run_id == run.id
      assert metadata.kind == :delegate
    end

    test "emits [:magus, :agents, :run, :started]" do
      attach([[:magus, :agents, :run, :started]])

      run = %{
        id: Ash.UUIDv7.generate(),
        source: :manual_trigger,
        target_agent_id: nil,
        kind: :subtask
      }

      assert :ok = Telemetry.run_event(:started, run)

      assert_receive {:telemetry_event, [:magus, :agents, :run, :started], %{count: 1}, metadata}
      assert metadata.source == :manual_trigger
      assert metadata.target_agent_id == nil
      assert metadata.run_id == run.id
      assert metadata.kind == :subtask
    end

    test "emits [:magus, :agents, :run, :completed]" do
      attach([[:magus, :agents, :run, :completed]])

      run = %{id: Ash.UUIDv7.generate(), source: :mention, target_agent_id: nil, kind: :consult}

      assert :ok = Telemetry.run_event(:completed, run)

      assert_receive {:telemetry_event, [:magus, :agents, :run, :completed], %{count: 1}, _}
    end

    test "emits [:magus, :agents, :run, :failed]" do
      attach([[:magus, :agents, :run, :failed]])

      run = %{
        id: Ash.UUIDv7.generate(),
        source: :inbox_urgent,
        target_agent_id: "agent-x",
        kind: :delegate
      }

      assert :ok = Telemetry.run_event(:failed, run)

      assert_receive {:telemetry_event, [:magus, :agents, :run, :failed], %{count: 1}, metadata}
      assert metadata.source == :inbox_urgent
    end

    test "emits [:magus, :agents, :run, :timed_out]" do
      attach([[:magus, :agents, :run, :timed_out]])

      run = %{
        id: Ash.UUIDv7.generate(),
        source: :heartbeat,
        target_agent_id: "agent-y",
        kind: :delegate
      }

      assert :ok = Telemetry.run_event(:timed_out, run)

      assert_receive {:telemetry_event, [:magus, :agents, :run, :timed_out], %{count: 1}, _}
    end

    test "stringifies run_id and target_agent_id when given raw ids" do
      attach([[:magus, :agents, :run, :enqueued]])

      run_id = Ash.UUIDv7.generate()

      run = %{id: run_id, source: :heartbeat, target_agent_id: nil, kind: :delegate}

      assert :ok = Telemetry.run_event(:enqueued, run)

      assert_receive {:telemetry_event, _event, _measurements, metadata}
      assert metadata.run_id == run_id
      assert is_binary(metadata.run_id)
    end

    test "never raises on a malformed run" do
      assert :ok = Telemetry.run_event(:enqueued, %{})
      assert :ok = Telemetry.run_event(:completed, nil)
    end
  end

  describe "wake_event/2" do
    test "emits [:magus, :agents, :wake, :urgent] with source + target_agent_id" do
      attach([[:magus, :agents, :wake, :urgent]])

      assert :ok =
               Telemetry.wake_event(:urgent, %{
                 target_agent_id: "agent-abc",
                 source: :inbox_urgent
               })

      assert_receive {:telemetry_event, [:magus, :agents, :wake, :urgent], %{count: 1}, metadata}
      assert metadata.target_agent_id == "agent-abc"
      assert metadata.source == :inbox_urgent
    end

    test "emits [:magus, :agents, :wake, :skipped]" do
      attach([[:magus, :agents, :wake, :skipped]])

      assert :ok =
               Telemetry.wake_event(:skipped, %{
                 target_agent_id: "agent-abc",
                 source: :inbox_urgent,
                 reason: :budget_exceeded
               })

      assert_receive {:telemetry_event, [:magus, :agents, :wake, :skipped], %{count: 1}, metadata}
      assert metadata.reason == :budget_exceeded
    end

    test "never raises on malformed metadata" do
      assert :ok = Telemetry.wake_event(:urgent, %{})
      assert :ok = Telemetry.wake_event(:skipped, nil)
    end
  end

  describe "integration: RunOrchestrator.enqueue fires [:magus, :agents, :run, :enqueued]" do
    test "fires on a newly created run", %{user: user, source_conversation: source_conversation} do
      attach([[:magus, :agents, :run, :enqueued]])

      target_conversation = generate(conversation(actor: user, is_task_conversation: true))

      attrs = %{
        kind: :subtask,
        source_conversation_id: source_conversation.id,
        target_conversation_id: target_conversation.id,
        request_id: "request-#{Ash.UUIDv7.generate()}",
        objective: "Do the thing",
        metadata: %{}
      }

      {:ok, run} = RunOrchestrator.enqueue(attrs)

      assert_receive {:telemetry_event, [:magus, :agents, :run, :enqueued], %{count: 1}, metadata}
      assert metadata.run_id == run.id
    end

    test "does not fire again for an idempotency-key replay", %{
      user: user,
      source_conversation: source_conversation
    } do
      target_conversation = generate(conversation(actor: user, is_task_conversation: true))
      idempotency_key = "idem-#{Ash.UUIDv7.generate()}"

      attrs = %{
        kind: :delegate,
        source_conversation_id: source_conversation.id,
        target_conversation_id: target_conversation.id,
        request_id: "request-#{Ash.UUIDv7.generate()}",
        idempotency_key: idempotency_key,
        objective: "Do the thing",
        metadata: %{}
      }

      {:ok, _run1} = RunOrchestrator.enqueue(attrs)

      attach([[:magus, :agents, :run, :enqueued]])

      {:ok, _run2} =
        RunOrchestrator.enqueue(%{attrs | request_id: "request-#{Ash.UUIDv7.generate()}"})

      refute_receive {:telemetry_event, [:magus, :agents, :run, :enqueued], _, _}
    end
  end
end
