defmodule Magus.Integrations.ThresholdCheckerTest do
  use Magus.DataCase, async: true

  alias Magus.Integrations.ThresholdChecker
  alias Magus.Integrations.Providers.LogSource
  alias Magus.Integrations.Providers.RssSource

  import Magus.Generators

  setup do
    user = generate(user())
    agent = custom_agent(user, %{name: "Monitor"})

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

  describe "check/3 for logs" do
    test "creates inbox event when error threshold is met", %{
      integration: integration,
      user: user,
      agent: agent
    } do
      now = DateTime.utc_now()

      entries =
        for i <- 1..3 do
          {:ok, entry} =
            Magus.Integrations.create_ingestion_entry(
              %{
                user_integration_id: integration.id,
                user_id: user.id,
                source_type: :log,
                severity: :error,
                content: "Error #{i}: connection refused",
                occurred_at: DateTime.add(now, -i * 30, :second),
                content_hash:
                  :crypto.hash(:sha256, "error-#{i}-#{System.unique_integer()}")
                  |> Base.encode16(case: :lower)
              },
              authorize?: false
            )

          entry
        end

      assert {:ok, :escalated} = ThresholdChecker.check(integration, entries, LogSource)

      # Verify inbox event was created
      {:ok, events} = Magus.Agents.list_pending_events(agent.id, authorize?: false)
      assert length(events) >= 1

      event = List.first(events)
      assert event.event_type == :integration
      assert event.urgency == :deferred
      assert event.source_type == :integration
    end

    test "does not create inbox event when below threshold", %{
      integration: integration,
      user: user,
      agent: agent
    } do
      now = DateTime.utc_now()

      entries =
        for i <- 1..2 do
          {:ok, entry} =
            Magus.Integrations.create_ingestion_entry(
              %{
                user_integration_id: integration.id,
                user_id: user.id,
                source_type: :log,
                severity: :error,
                content: "Error #{i}",
                occurred_at: DateTime.add(now, -i * 30, :second),
                content_hash:
                  :crypto.hash(:sha256, "below-#{i}-#{System.unique_integer()}")
                  |> Base.encode16(case: :lower)
              },
              authorize?: false
            )

          entry
        end

      assert {:ok, :below_threshold} = ThresholdChecker.check(integration, entries, LogSource)

      {:ok, events} = Magus.Agents.list_pending_events(agent.id, authorize?: false)
      assert Enum.empty?(events)
    end

    test "deduplicates inbox events within same window", %{
      integration: integration,
      user: user
    } do
      now = DateTime.utc_now()

      for batch <- 1..2 do
        entries =
          for i <- 1..3 do
            {:ok, entry} =
              Magus.Integrations.create_ingestion_entry(
                %{
                  user_integration_id: integration.id,
                  user_id: user.id,
                  source_type: :log,
                  severity: :error,
                  content: "Error batch#{batch}-#{i}",
                  occurred_at: DateTime.add(now, -i * 10, :second),
                  content_hash:
                    :crypto.hash(:sha256, "dedup-#{batch}-#{i}-#{System.unique_integer()}")
                    |> Base.encode16(case: :lower)
                },
                authorize?: false
              )

            entry
          end

        ThresholdChecker.check(integration, entries, LogSource)
      end

      # Should only have 1 inbox event due to idempotency
      {:ok, events} =
        Magus.Agents.list_pending_events(integration.custom_agent_id, authorize?: false)

      integration_events = Enum.filter(events, &(&1.event_type == :integration))
      assert length(integration_events) == 1
    end
  end

  describe "check/3 for RSS" do
    test "creates inbox event when new RSS items are ingested", %{
      integration: integration,
      user: user
    } do
      now = DateTime.utc_now()

      entries =
        for i <- 1..3 do
          {:ok, entry} =
            Magus.Integrations.create_ingestion_entry(
              %{
                user_integration_id: integration.id,
                user_id: user.id,
                source_type: :rss,
                severity: :info,
                title: "Article #{i}",
                content: "Content for article #{i}",
                occurred_at: DateTime.add(now, -i * 60, :second),
                content_hash:
                  :crypto.hash(:sha256, "rss-#{i}-#{System.unique_integer()}")
                  |> Base.encode16(case: :lower)
              },
              authorize?: false
            )

          entry
        end

      assert {:ok, :escalated} = ThresholdChecker.check(integration, entries, RssSource)
    end

    test "does not escalate when no new RSS items", %{integration: integration} do
      assert {:ok, :below_threshold} = ThresholdChecker.check(integration, [], RssSource)
    end
  end
end
