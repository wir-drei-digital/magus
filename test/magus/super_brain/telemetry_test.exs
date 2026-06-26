defmodule Magus.SuperBrain.TelemetryTest do
  @moduledoc """
  Verifies that the Telemetry counter helpers emit events with the
  documented names and metadata. Span events are covered by the
  worker-level tests; this file pins the counters.
  """

  use ExUnit.Case, async: false

  alias Magus.SuperBrain.Telemetry, as: SBTelemetry

  setup do
    test_pid = self()
    handler_id = "sb-telemetry-test-#{System.unique_integer([:positive])}"

    events = [
      [:super_brain, :embedder, :failure],
      [:super_brain, :sanitizer, :predicate_fallback],
      [:super_brain, :sanitizer, :type_fallback],
      [:super_brain, :budget, :exhausted],
      [:super_brain, :drift, :detected]
    ]

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        fn name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  test "embedder_failure emits the counter event" do
    SBTelemetry.embedder_failure(:timeout)

    assert_receive {:telemetry_event, [:super_brain, :embedder, :failure], %{count: 1},
                    %{reason: :timeout}}
  end

  test "sanitizer_predicate_fallback carries the from_predicate" do
    SBTelemetry.sanitizer_predicate_fallback("...")

    assert_receive {:telemetry_event, [:super_brain, :sanitizer, :predicate_fallback],
                    %{count: 1}, %{from_predicate: "..."}}
  end

  test "sanitizer_type_fallback carries the from_type" do
    SBTelemetry.sanitizer_type_fallback("alien")

    assert_receive {:telemetry_event, [:super_brain, :sanitizer, :type_fallback], %{count: 1},
                    %{from_type: "alien"}}
  end

  test "budget_exhausted carries user_id and date" do
    today = Date.utc_today()
    SBTelemetry.budget_exhausted("user-1", today)

    assert_receive {:telemetry_event, [:super_brain, :budget, :exhausted], %{count: 1},
                    %{user_id: "user-1", date: ^today}}
  end

  test "drift_detected passes the metadata map through" do
    metadata = %{accessor_type: :user, user_id: "u1", workspace_id: nil}
    SBTelemetry.drift_detected(metadata)

    assert_receive {:telemetry_event, [:super_brain, :drift, :detected], %{count: 1}, ^metadata}
  end
end
