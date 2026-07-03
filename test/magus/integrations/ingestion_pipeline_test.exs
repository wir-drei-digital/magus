defmodule Magus.Integrations.IngestionPipelineTest do
  @moduledoc """
  Integration test exercising the full ingestion pipeline:
  webhook payload → parse → classify → store → threshold check.
  """
  use Magus.DataCase, async: true

  alias Magus.Integrations.ProcessIngestion
  alias Magus.Integrations.Providers.LogSource

  import Magus.Generators

  setup do
    user = generate(user())
    agent = custom_agent(user, %{name: "Pipeline Monitor"})

    {:ok, integration} =
      Magus.Integrations.create_user_integration(
        :log_source,
        %{
          custom_agent_id: agent.id,
          user_id: user.id,
          config: %{"error_threshold" => 3, "window_minutes" => 5}
        },
        actor: user
      )

    {:ok, integration} =
      Magus.Integrations.activate_user_integration(integration, actor: user)

    %{user: user, agent: agent, integration: integration}
  end

  describe "full log ingestion pipeline" do
    test "webhook payload → parse → classify → store → threshold check", %{
      integration: integration,
      agent: agent
    } do
      # Simulate Vector sending a batch of 3 error logs (including crash signatures)
      payload = %{
        "entries" => [
          %{
            "message" => "GenServer terminating: timeout",
            "level" => "error",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          },
          %{
            "message" => "** (EXIT) killed",
            "level" => "error",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          },
          %{
            "message" => "Connection refused to db",
            "level" => "error",
            "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
          }
        ]
      }

      assert {:ok, %{ingested: 3}} = ProcessIngestion.run(LogSource, integration, payload, [])

      # Verify entries were stored
      {:ok, entries} =
        Magus.Integrations.list_ingestion_entries(integration.id, authorize?: false)

      assert length(entries) == 3

      # Verify crash entries were classified as critical
      critical_entries = Enum.filter(entries, &(&1.severity == :critical))
      assert length(critical_entries) >= 1

      # Verify threshold was met and inbox event was created
      {:ok, events} = Magus.Agents.list_pending_events(agent.id, authorize?: false)
      integration_events = Enum.filter(events, &(&1.event_type == :integration))
      assert length(integration_events) == 1

      event = List.first(integration_events)
      assert event.urgency == :immediate
      assert String.contains?(event.title, "errors")
    end

    test "deduplicates identical log entries", %{integration: integration} do
      payload = %{
        "message" => "Same error message",
        "level" => "error",
        "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
      }

      assert {:ok, %{ingested: 1}} = ProcessIngestion.run(LogSource, integration, payload, [])
      assert {:ok, %{ingested: 0}} = ProcessIngestion.run(LogSource, integration, payload, [])
    end
  end
end
