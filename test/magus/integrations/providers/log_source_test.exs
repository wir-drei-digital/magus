defmodule Magus.Integrations.Providers.LogSourceTest do
  use ExUnit.Case, async: true

  alias Magus.Integrations.Providers.LogSource

  describe "metadata" do
    test "returns correct key and auth type" do
      assert LogSource.key() == :log_source
      assert LogSource.auth_type() == :webhook_only
      assert LogSource.source_type() == :data_source
    end

    test "returns search tools" do
      tools = LogSource.tools()
      assert length(tools) == 2
      tool_keys = Enum.map(tools, & &1.key)
      assert :search_entries in tool_keys
      assert :get_source_status in tool_keys
    end
  end

  describe "parse_ingestion_payload/2" do
    test "parses single JSON log entry" do
      payload = %{
        "message" => "GenServer terminating",
        "timestamp" => "2026-03-21T10:30:00Z",
        "level" => "error",
        "metadata" => %{"fly_region" => "iad", "app" => "magus"}
      }

      assert {:ok, [entry]} = LogSource.parse_ingestion_payload(payload, [])
      assert entry.content == "GenServer terminating"
      assert entry.severity == :error
      assert entry.metadata["fly_region"] == "iad"
    end

    test "parses batch of log entries" do
      payload = %{
        "entries" => [
          %{
            "message" => "Request started",
            "level" => "info",
            "timestamp" => "2026-03-21T10:30:00Z"
          },
          %{"message" => "DB timeout", "level" => "error", "timestamp" => "2026-03-21T10:30:01Z"}
        ]
      }

      assert {:ok, entries} = LogSource.parse_ingestion_payload(payload, [])
      assert length(entries) == 2
    end

    test "handles plain text fallback" do
      payload = %{"message" => "2026-03-21 ERROR Something broke"}

      assert {:ok, [entry]} = LogSource.parse_ingestion_payload(payload, [])
      assert entry.content == "2026-03-21 ERROR Something broke"
    end
  end

  describe "classify/1" do
    test "detects critical crash signatures" do
      assert %{severity: :critical} =
               LogSource.classify(%{content: "GenServer terminating", severity: :error})

      assert %{severity: :critical} =
               LogSource.classify(%{content: "** (EXIT) killed", severity: :error})

      assert %{severity: :critical} =
               LogSource.classify(%{content: "got SIGTERM", severity: :info})
    end

    test "preserves severity for non-crash entries" do
      assert %{severity: :error} =
               LogSource.classify(%{content: "connection refused", severity: :error})

      assert %{severity: :info} =
               LogSource.classify(%{content: "Request completed", severity: :info})
    end
  end
end
