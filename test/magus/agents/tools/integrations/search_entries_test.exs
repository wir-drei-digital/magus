defmodule Magus.Agents.Tools.Integrations.SearchEntriesTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Tools.Integrations.SearchEntries
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

    for i <- 1..5 do
      sev = if rem(i, 2) == 0, do: :error, else: :info

      Magus.Integrations.create_ingestion_entry(
        %{
          user_integration_id: integration.id,
          user_id: user.id,
          source_type: :log,
          severity: sev,
          content:
            "Log entry #{i}: #{if sev == :error, do: "connection refused", else: "request completed"}",
          occurred_at: DateTime.add(now, -i * 60, :second),
          content_hash:
            :crypto.hash(:sha256, "se-#{i}-#{System.unique_integer()}")
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
      assert SearchEntries.display_name() == "Searching ingested data..."
    end
  end

  describe "summarize_output/1" do
    test "summarizes entries count" do
      assert SearchEntries.summarize_output(%{entries: [%{}, %{}]}) == "Found 2 entries"
    end

    test "summarizes error" do
      assert SearchEntries.summarize_output(%{error: "fail"}) == "Error: fail"
    end

    test "summarizes unknown output" do
      assert SearchEntries.summarize_output(%{}) == "Search completed"
    end
  end

  describe "run/2" do
    test "returns entries matching query", %{context: context} do
      assert {:ok, result} = SearchEntries.run(%{"query" => "connection refused"}, context)
      assert length(result.entries) > 0
      assert Enum.all?(result.entries, &String.contains?(&1.content, "connection refused"))
    end

    test "filters by severity", %{context: context} do
      assert {:ok, result} = SearchEntries.run(%{"severity" => "error"}, context)
      assert length(result.entries) > 0
      assert Enum.all?(result.entries, &(&1.severity == :error))
    end

    test "filters by source_type", %{context: context} do
      assert {:ok, result} = SearchEntries.run(%{"source_type" => "log"}, context)
      assert length(result.entries) > 0
      assert Enum.all?(result.entries, &(&1.source_type == :log))
    end

    test "returns all entries with no filters", %{context: context} do
      assert {:ok, result} = SearchEntries.run(%{}, context)
      assert length(result.entries) == 5
    end

    test "respects limit parameter", %{context: context} do
      assert {:ok, result} = SearchEntries.run(%{"limit" => 2}, context)
      assert length(result.entries) == 2
    end

    test "returns error without user_id in context" do
      assert {:ok, %{error: msg}} = SearchEntries.run(%{}, %{})
      assert msg =~ "Missing required context"
    end
  end
end
