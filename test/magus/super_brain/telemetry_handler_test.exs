defmodule Magus.SuperBrain.TelemetryHandlerTest do
  @moduledoc """
  Smoke tests for the Logger-backed telemetry sink.

  Asserting on log output fights with `config :logger, level: :none`
  in `config/test.exs`, so these tests pin the contract instead:

    * `attach/0` is idempotent.
    * `handle_event/4` does not raise for any documented event shape.
    * The catch-all clause covers events outside the documented set so
      a future producer that forgets to add a clause here still
      surfaces (at debug level) rather than crashing the BEAM's
      telemetry dispatcher.

  Side effects (the actual Logger calls) are exercised in production;
  the test ensures the dispatcher never sees a raise.
  """

  use ExUnit.Case, async: false

  alias Magus.SuperBrain.TelemetryHandler

  setup do
    :ok = TelemetryHandler.attach()
    on_exit(fn -> TelemetryHandler.detach() end)
    :ok
  end

  describe "attach/0" do
    test "is idempotent" do
      assert :ok = TelemetryHandler.attach()
      assert :ok = TelemetryHandler.attach()
    end
  end

  describe "events/0" do
    test "returns the static list of subscribed events" do
      events = TelemetryHandler.events()
      assert is_list(events)
      assert Enum.all?(events, &match?([:super_brain | _], &1))

      # Spot-check a few key events are present.
      assert [:super_brain, :extract, :stop] in events
      assert [:super_brain, :migration, :progress] in events
      assert [:super_brain, :embedder, :failure] in events
    end
  end

  describe "handle_event/4 does not raise for documented event shapes" do
    test "span :stop" do
      :telemetry.execute(
        [:super_brain, :extract, :stop],
        %{duration: System.convert_time_unit(42, :millisecond, :native)},
        %{user_id: "u1", graph_name: "brain:abc"}
      )
    end

    test "span :exception" do
      :telemetry.execute(
        [:super_brain, :build_super_full, :exception],
        %{duration: 1_000_000},
        %{user_id: "u1", kind: :error, reason: :boom}
      )
    end

    test "embedder.failure" do
      :telemetry.execute(
        [:super_brain, :embedder, :failure],
        %{count: 1},
        %{reason: :timeout}
      )
    end

    test "budget.exhausted" do
      :telemetry.execute(
        [:super_brain, :budget, :exhausted],
        %{count: 1},
        %{user_id: "u1", date: Date.utc_today()}
      )
    end

    test "drift.detected" do
      :telemetry.execute(
        [:super_brain, :drift, :detected],
        %{count: 1},
        %{accessor_type: :user, user_id: "u1", workspace_id: nil}
      )
    end

    test "sanitizer.*" do
      for kind <- [:predicate_fallback, :type_fallback, :ambiguous_edge_endpoint] do
        :telemetry.execute(
          [:super_brain, :sanitizer, kind],
          %{count: 1},
          %{from_type: "Unknown"}
        )
      end
    end

    test "migration.progress (stale > 0)" do
      :telemetry.execute(
        [:super_brain, :migration, :progress],
        %{
          total_rows: 10,
          stale_rows: 3,
          enqueued: 3,
          current_marker_rows: 7,
          probe_errors: 0
        },
        %{current_version: 1}
      )
    end

    test "migration.progress (stale = 0, steady state)" do
      :telemetry.execute(
        [:super_brain, :migration, :progress],
        %{
          total_rows: 10,
          stale_rows: 0,
          enqueued: 0,
          current_marker_rows: 10,
          probe_errors: 0
        },
        %{current_version: 1}
      )
    end
  end

  describe "unknown :super_brain event" do
    test "the catch-all clause handles novel event names without raising" do
      :ok =
        :telemetry.attach(
          "test-attach-novel",
          [:super_brain, :totally_novel, :counter],
          &TelemetryHandler.handle_event/4,
          nil
        )

      try do
        :telemetry.execute(
          [:super_brain, :totally_novel, :counter],
          %{count: 1},
          %{}
        )
      after
        :telemetry.detach("test-attach-novel")
      end
    end
  end
end
