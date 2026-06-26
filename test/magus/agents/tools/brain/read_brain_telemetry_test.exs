defmodule Magus.Agents.Tools.Brain.ReadBrainTelemetryTest do
  @moduledoc """
  Structured telemetry events emitted from ReadBrain tool calls.

  Currently covers the read_source staleness signal (moved here from
  EditBrainTelemetryTest when read_source moved onto the ReadBrain tool).
  """

  use Magus.ResourceCase, async: false

  alias Magus.Agents.Tools.Brain.ReadBrain
  alias Magus.Brain

  defp attach(event, suffix \\ "") do
    test_pid = self()
    handler_id = "test-#{Enum.join(event, "-")}-#{suffix}-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      event,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  defp setup_brain do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Telemetry Brain"}, actor: user)
    context = %{user_id: user.id, user: user, brain_id: brain.id}
    %{user: user, brain: brain, context: context}
  end

  describe "[:brain, :read_source, :staleness]" do
    test "fires when read_source returns a source older than 7 days" do
      %{user: user, brain: brain, context: _context} = setup_brain()

      stale_at = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
      url = "https://example.test/stale-#{System.unique_integer([:positive])}"

      {:ok, source} =
        Magus.Brain.Source
        |> Ash.Changeset.for_create(
          :from_legacy_block,
          %{
            brain_id: brain.id,
            url: url,
            title: "Stale Article",
            ingest_status: :ingested,
            ingested_content: "Old content body",
            ingested_at: stale_at
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      attach([:brain, :read_source, :staleness])

      {:ok, result} =
        ReadBrain.run(
          %{"action" => "read_source", "source_id" => source.id},
          %{user_id: user.id, user: user}
        )

      assert result.action == "read_source"
      assert result.source_id == source.id

      assert_receive {:telemetry, [:brain, :read_source, :staleness], measurements, metadata}

      assert measurements.age_days >= 30
      assert metadata.brain_id == brain.id
      assert metadata.source_id == source.id
      assert metadata.url == url
      assert metadata.ingest_status == :ingested
    end

    test "does NOT fire when read_source returns a fresh source" do
      %{user: user, brain: brain} = setup_brain()

      fresh_at = DateTime.add(DateTime.utc_now(), -1 * 86_400, :second)
      url = "https://example.test/fresh-#{System.unique_integer([:positive])}"

      {:ok, source} =
        Magus.Brain.Source
        |> Ash.Changeset.for_create(
          :from_legacy_block,
          %{
            brain_id: brain.id,
            url: url,
            ingest_status: :ingested,
            ingested_content: "Fresh content",
            ingested_at: fresh_at
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      attach([:brain, :read_source, :staleness], "fresh")

      {:ok, _result} =
        ReadBrain.run(
          %{"action" => "read_source", "source_id" => source.id},
          %{user_id: user.id, user: user}
        )

      refute_receive {:telemetry, [:brain, :read_source, :staleness], _, _}, 100
    end

    test "does NOT fire when ingested_at is nil" do
      %{user: user, brain: brain} = setup_brain()
      url = "https://example.test/never-#{System.unique_integer([:positive])}"

      {:ok, source} =
        Magus.Brain.Source
        |> Ash.Changeset.for_create(
          :from_legacy_block,
          %{
            brain_id: brain.id,
            url: url,
            ingest_status: :pending
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      attach([:brain, :read_source, :staleness], "nil")

      {:ok, _result} =
        ReadBrain.run(
          %{"action" => "read_source", "source_id" => source.id},
          %{user_id: user.id, user: user}
        )

      refute_receive {:telemetry, [:brain, :read_source, :staleness], _, _}, 100
    end
  end
end
