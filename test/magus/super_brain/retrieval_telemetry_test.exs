defmodule Magus.SuperBrain.RetrievalTelemetryTest do
  use Magus.ResourceCase, async: false

  alias Magus.SuperBrain.Retrieval

  test "emits mode + result_count in the retrieval span metadata" do
    user = generate(user())
    test_pid = self()

    :telemetry.attach(
      "retrieval-meta-test",
      [:super_brain, :retrieval, :stop],
      fn _event, _measure, meta, _config -> send(test_pid, {:meta, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("retrieval-meta-test") end)

    {:ok, _} =
      Retrieval.search(user, query: "anything", query_embedding: List.duplicate(0.0, 1536))

    assert_receive {:meta, meta}, 2_000
    assert Map.has_key?(meta, :mode)
    assert Map.has_key?(meta, :result_count)
  end
end
