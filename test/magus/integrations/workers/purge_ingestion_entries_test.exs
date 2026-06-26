defmodule Magus.Integrations.Workers.PurgeIngestionEntriesTest do
  use Magus.DataCase, async: true
  use Oban.Testing, repo: Magus.Repo

  import Magus.Generators

  alias Magus.Integrations.Workers.PurgeIngestionEntries

  setup do
    user = generate(user())
    agent = custom_agent(user, %{name: "Purger"})

    {:ok, integration} =
      Magus.Integrations.create_user_integration(
        :log_source,
        %{
          custom_agent_id: agent.id,
          user_id: user.id,
          config: %{"retention_days" => 7}
        },
        actor: user
      )

    {:ok, integration} =
      Magus.Integrations.activate_user_integration(integration, actor: user)

    # Insert old entry (8 days ago)
    {:ok, old_entry} =
      Magus.Integrations.create_ingestion_entry(
        %{
          user_integration_id: integration.id,
          user_id: user.id,
          source_type: :log,
          severity: :info,
          content: "old log",
          occurred_at: DateTime.add(DateTime.utc_now(), -8 * 86400, :second),
          content_hash:
            :crypto.hash(:sha256, "old-#{System.unique_integer()}") |> Base.encode16(case: :lower)
        },
        authorize?: false
      )

    # Insert recent entry (1 day ago)
    {:ok, recent_entry} =
      Magus.Integrations.create_ingestion_entry(
        %{
          user_integration_id: integration.id,
          user_id: user.id,
          source_type: :log,
          severity: :info,
          content: "recent log",
          occurred_at: DateTime.add(DateTime.utc_now(), -86400, :second),
          content_hash:
            :crypto.hash(:sha256, "recent-#{System.unique_integer()}")
            |> Base.encode16(case: :lower)
        },
        authorize?: false
      )

    %{user: user, integration: integration, old_entry: old_entry, recent_entry: recent_entry}
  end

  test "purges entries older than retention_days", %{
    integration: integration,
    old_entry: old_entry,
    recent_entry: recent_entry
  } do
    assert :ok = PurgeIngestionEntries.perform(%Oban.Job{args: %{}})

    # Old entry should be gone
    {:ok, entries} =
      Magus.Integrations.list_ingestion_entries(integration.id, authorize?: false)

    entry_ids = Enum.map(entries, & &1.id)
    refute old_entry.id in entry_ids
    assert recent_entry.id in entry_ids
  end

  test "uses default retention of 7 days when config is missing", %{user: user} do
    agent2 = custom_agent(user, %{name: "No Config"})

    {:ok, integration2} =
      Magus.Integrations.create_user_integration(
        :rss_source,
        %{custom_agent_id: agent2.id, user_id: user.id, config: %{}},
        actor: user
      )

    {:ok, integration2} =
      Magus.Integrations.activate_user_integration(integration2, actor: user)

    # Insert entry 8 days old (should be purged with default 7-day retention)
    {:ok, old_entry} =
      Magus.Integrations.create_ingestion_entry(
        %{
          user_integration_id: integration2.id,
          user_id: user.id,
          source_type: :rss,
          severity: :info,
          content: "old rss item",
          occurred_at: DateTime.add(DateTime.utc_now(), -8 * 86400, :second),
          content_hash:
            :crypto.hash(:sha256, "old-rss-#{System.unique_integer()}")
            |> Base.encode16(case: :lower)
        },
        authorize?: false
      )

    assert :ok = PurgeIngestionEntries.perform(%Oban.Job{args: %{}})

    {:ok, entries} =
      Magus.Integrations.list_ingestion_entries(integration2.id, authorize?: false)

    entry_ids = Enum.map(entries, & &1.id)
    refute old_entry.id in entry_ids
  end

  test "does not purge entries from inactive integrations", %{user: user} do
    agent3 = custom_agent(user, %{name: "Inactive"})

    {:ok, integration3} =
      Magus.Integrations.create_user_integration(
        :log_source,
        %{
          custom_agent_id: agent3.id,
          user_id: user.id,
          config: %{"retention_days" => 1}
        },
        actor: user
      )

    # Do NOT activate — integration stays in :pending status

    {:ok, old_entry} =
      Magus.Integrations.create_ingestion_entry(
        %{
          user_integration_id: integration3.id,
          user_id: user.id,
          source_type: :log,
          severity: :info,
          content: "should stay",
          occurred_at: DateTime.add(DateTime.utc_now(), -30 * 86400, :second),
          content_hash:
            :crypto.hash(:sha256, "inactive-#{System.unique_integer()}")
            |> Base.encode16(case: :lower)
        },
        authorize?: false
      )

    assert :ok = PurgeIngestionEntries.perform(%Oban.Job{args: %{}})

    {:ok, entries} =
      Magus.Integrations.list_ingestion_entries(integration3.id, authorize?: false)

    entry_ids = Enum.map(entries, & &1.id)
    assert old_entry.id in entry_ids
  end
end
