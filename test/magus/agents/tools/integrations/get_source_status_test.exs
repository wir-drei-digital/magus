defmodule Magus.Agents.Tools.Integrations.GetSourceStatusTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Tools.Integrations.GetSourceStatus
  alias Magus.Generators

  setup do
    user = Generators.generate(Generators.user())
    agent = Generators.custom_agent(user)

    {:ok, integration} =
      Magus.Integrations.create_user_integration(
        :log_source,
        %{user_id: user.id, custom_agent_id: agent.id, config: %{}},
        actor: user
      )

    {:ok, integration} =
      Magus.Integrations.activate_user_integration(integration, authorize?: false)

    now = DateTime.utc_now()

    for i <- 1..3 do
      Magus.Integrations.create_ingestion_entry(
        %{
          user_integration_id: integration.id,
          user_id: user.id,
          source_type: :log,
          severity: :error,
          content: "Error #{i}",
          occurred_at: DateTime.add(now, -i * 60, :second),
          content_hash:
            :crypto.hash(:sha256, "gs-#{i}-#{System.unique_integer()}")
            |> Base.encode16(case: :lower)
        },
        authorize?: false
      )
    end

    context = %{user_id: user.id, conversation_id: Ash.UUID.generate()}
    %{user: user, context: context}
  end

  describe "display_name/0" do
    test "returns display string" do
      assert GetSourceStatus.display_name() == "Checking source status..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes sources count" do
      assert GetSourceStatus.summarize_output(%{sources: [%{}, %{}]}) == "2 source(s) reporting"
    end

    test "summarizes error" do
      assert GetSourceStatus.summarize_output(%{error: "fail"}) == "Error: fail"
    end

    test "summarizes unknown output" do
      assert GetSourceStatus.summarize_output(%{}) == "Status check completed"
    end
  end

  describe "run/2" do
    test "returns source status summary", %{context: context} do
      assert {:ok, result} = GetSourceStatus.run(%{}, context)
      assert is_list(result.sources)
      assert length(result.sources) > 0

      source = List.first(result.sources)
      assert source.source_type == :log
      assert source.error_count >= 0
      assert source.total_entries >= 0
    end

    test "filters by source_type", %{context: context} do
      # No RSS sources exist, so filtering by :rss should return empty
      assert {:ok, result} = GetSourceStatus.run(%{"source_type" => "rss"}, context)
      assert result.sources == []
    end

    test "returns error without user_id in context" do
      assert {:ok, %{error: msg}} = GetSourceStatus.run(%{}, %{})
      assert msg =~ "Missing required context"
    end
  end
end
