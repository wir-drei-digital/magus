defmodule Magus.Integrations.IngestionEntryTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  setup do
    user = generate(user())
    agent = custom_agent(user, %{name: "Log Monitor"})

    {:ok, integration} =
      Magus.Integrations.create_user_integration(
        :log_source,
        %{
          custom_agent_id: agent.id,
          user_id: user.id,
          config: %{"error_threshold" => 5, "window_minutes" => 5}
        },
        actor: user
      )

    {:ok, integration} =
      Magus.Integrations.activate_user_integration(integration, actor: user)

    %{user: user, agent: agent, integration: integration}
  end

  describe "create" do
    test "creates an ingestion entry with required fields", %{
      integration: integration,
      user: user
    } do
      attrs = %{
        user_integration_id: integration.id,
        user_id: user.id,
        source_type: :log,
        severity: :error,
        content: "GenServer terminating",
        metadata: %{"level" => "error", "module" => "MyApp.Repo"},
        occurred_at: DateTime.utc_now(),
        content_hash:
          :crypto.hash(:sha256, "GenServer terminating") |> Base.encode16(case: :lower)
      }

      assert {:ok, entry} = Magus.Integrations.create_ingestion_entry(attrs, authorize?: false)
      assert entry.source_type == :log
      assert entry.severity == :error
      assert entry.content == "GenServer terminating"
      assert entry.user_id == user.id
    end

    test "deduplicates by content_hash per integration", %{
      integration: integration,
      user: user
    } do
      hash = :crypto.hash(:sha256, "duplicate content") |> Base.encode16(case: :lower)

      attrs = %{
        user_integration_id: integration.id,
        user_id: user.id,
        source_type: :log,
        severity: :info,
        content: "duplicate content",
        occurred_at: DateTime.utc_now(),
        content_hash: hash
      }

      assert {:ok, _} = Magus.Integrations.create_ingestion_entry(attrs, authorize?: false)
      assert {:error, _} = Magus.Integrations.create_ingestion_entry(attrs, authorize?: false)
    end
  end

  describe "queries" do
    test "list_ingestion_entries filters by integration and time range", %{
      integration: integration,
      user: user
    } do
      now = DateTime.utc_now()

      for i <- 1..3 do
        Magus.Integrations.create_ingestion_entry(
          %{
            user_integration_id: integration.id,
            user_id: user.id,
            source_type: :log,
            severity: :info,
            content: "log line #{i}",
            occurred_at: DateTime.add(now, -i * 60, :second),
            content_hash: :crypto.hash(:sha256, "log line #{i}") |> Base.encode16(case: :lower)
          },
          authorize?: false
        )
      end

      {:ok, entries} =
        Magus.Integrations.list_ingestion_entries(
          integration.id,
          %{since: DateTime.add(now, -200, :second)},
          authorize?: false
        )

      assert length(entries) == 3
    end

    test "count_by_severity counts entries in time window", %{
      integration: integration,
      user: user
    } do
      now = DateTime.utc_now()

      for {sev, i} <- [{:error, 1}, {:error, 2}, {:info, 3}] do
        Magus.Integrations.create_ingestion_entry(
          %{
            user_integration_id: integration.id,
            user_id: user.id,
            source_type: :log,
            severity: sev,
            content: "entry #{i}",
            occurred_at: DateTime.add(now, -60, :second),
            content_hash: :crypto.hash(:sha256, "entry #{i}") |> Base.encode16(case: :lower)
          },
          authorize?: false
        )
      end

      {:ok, count} =
        Magus.Integrations.count_ingestion_entries_by_severity(
          integration.id,
          :error,
          DateTime.add(now, -300, :second),
          authorize?: false
        )

      assert count == 2
    end
  end
end
