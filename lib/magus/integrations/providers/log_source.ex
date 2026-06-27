defmodule Magus.Integrations.Providers.LogSource do
  @moduledoc """
  Data source provider for application log ingestion via webhook.

  Accepts structured JSON from log shippers like Vector (Fly Log Shipper),
  Logflare, or custom HTTP senders. Classifies entries by severity and
  detects crash signatures for critical escalation.

  ## Expected payload formats

  Single entry:
      %{"message" => "...", "level" => "error", "timestamp" => "ISO8601", "metadata" => %{}}

  Batch:
      %{"entries" => [%{"message" => "...", ...}, ...]}
  """

  @behaviour Magus.Integrations.Providers.Behaviour
  @behaviour Magus.Integrations.Providers.DataSourceBehaviour

  @level_to_severity %{
    "emergency" => :critical,
    "alert" => :critical,
    "critical" => :critical,
    "error" => :error,
    "warning" => :warning,
    "warn" => :warning,
    "notice" => :info,
    "info" => :info,
    "debug" => :debug
  }

  # --- Base Behaviour callbacks ---

  @impl Magus.Integrations.Providers.Behaviour
  def key, do: :log_source

  @impl Magus.Integrations.Providers.Behaviour
  def name, do: "Log Source"

  @impl Magus.Integrations.Providers.Behaviour
  def description, do: "Ingest application logs via webhook (e.g., Fly Log Shipper, Vector)"

  @impl Magus.Integrations.Providers.Behaviour
  def auth_type, do: :webhook_only

  @impl Magus.Integrations.Providers.Behaviour
  def source_type, do: :data_source

  @impl Magus.Integrations.Providers.Behaviour
  def auth_help do
    %{
      text: """
      1. Connect the integration — a unique webhook URL will be generated
      2. Configure your log shipper (Vector, Fly Log Shipper, Logflare, etc.) to POST JSON to the webhook URL
      3. Send entries as {"message": "...", "level": "error"} or batch as {"entries": [...]}
      4. The agent will automatically classify entries by severity and detect crash signatures
      """,
      url: "https://vector.dev/docs/reference/configuration/sinks/http/",
      url_label: "Vector HTTP Sink Docs"
    }
  end

  @impl Magus.Integrations.Providers.Behaviour
  def operations, do: [:ingest]

  @impl Magus.Integrations.Providers.Behaviour
  def execute(_operation, _credentials, _params), do: {:error, :not_supported}

  @impl Magus.Integrations.Providers.Behaviour
  def on_credentials_saved(integration, _credentials) do
    secret = :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)

    config =
      (integration.config || %{})
      |> Map.put("webhook_secret", secret)

    # Persist the config here: the SetupIntegration reactor discards this hook's
    # return value, so (like the api/telegram providers) the provider must save
    # it, otherwise the webhook secret is lost and inbound webhooks can never
    # authenticate.
    with {:ok, _} <-
           Magus.Integrations.update_integration_config(
             integration,
             %{config: config},
             authorize?: false
           ) do
      {:ok, %{config: config}}
    end
  end

  @doc """
  Verifies inbound webhooks by checking the X-Webhook-Secret header
  against the stored secret in the integration config.
  """
  def verify_webhook(conn, integration) do
    expected = get_in(integration.config || %{}, ["webhook_secret"])

    case Plug.Conn.get_req_header(conn, "x-api-key") do
      [provided] when is_binary(provided) and is_binary(expected) ->
        if Plug.Crypto.secure_compare(provided, expected),
          do: :ok,
          else: {:error, :invalid_secret}

      _ ->
        {:error, :missing_secret}
    end
  end

  @impl Magus.Integrations.Providers.Behaviour
  def tools do
    [
      %{
        key: :search_entries,
        module: Magus.Agents.Tools.Integrations.SearchEntries,
        name: "Search Ingested Data",
        description: "Search logs, RSS feeds, and other ingested data sources"
      },
      %{
        key: :get_source_status,
        module: Magus.Agents.Tools.Integrations.GetSourceStatus,
        name: "Get Source Status",
        description: "Get a summary of recent activity from ingested data sources"
      }
    ]
  end

  # --- DataSourceBehaviour callbacks ---

  @impl Magus.Integrations.Providers.DataSourceBehaviour
  def parse_ingestion_payload(%{"entries" => entries}, _headers) when is_list(entries) do
    parsed = Enum.map(entries, &parse_single_entry/1)
    {:ok, parsed}
  end

  def parse_ingestion_payload(%{"message" => _} = entry, _headers) do
    {:ok, [parse_single_entry(entry)]}
  end

  def parse_ingestion_payload(payload, _headers) do
    {:error,
     {:invalid_payload,
      "Expected 'message' field or 'entries' array, got: #{inspect(Map.keys(payload))}"}}
  end

  @impl Magus.Integrations.Providers.DataSourceBehaviour
  def classify(%{content: content, severity: severity} = _entry) do
    if crash_signature?(content) do
      %{severity: :critical, title: extract_crash_title(content)}
    else
      %{severity: severity, title: nil}
    end
  end

  def classify(entry), do: %{severity: Map.get(entry, :severity, :info), title: nil}

  # Checks all entries in the rolling window, not just the new batch.
  # This means the threshold can fire even if the new batch has no errors,
  # as long as enough errors accumulated from previous ingestions.
  @impl Magus.Integrations.Providers.DataSourceBehaviour
  def should_create_inbox_event?(integration, _new_entries) do
    config = integration.config || %{}
    threshold = config["error_threshold"] || 5
    window_minutes = config["window_minutes"] || 5
    since = DateTime.add(DateTime.utc_now(), -window_minutes * 60, :second)

    error_count = count_errors_in_window(integration.id, since)
    error_count >= threshold
  end

  defp count_errors_in_window(integration_id, since) do
    error_count =
      case Magus.Integrations.count_ingestion_entries_by_severity(
             integration_id,
             :error,
             since,
             authorize?: false
           ) do
        {:ok, count} -> count
        _ -> 0
      end

    critical_count =
      case Magus.Integrations.count_ingestion_entries_by_severity(
             integration_id,
             :critical,
             since,
             authorize?: false
           ) do
        {:ok, count} -> count
        _ -> 0
      end

    error_count + critical_count
  end

  @impl Magus.Integrations.Providers.DataSourceBehaviour
  def build_inbox_event_attrs(integration, new_entries) do
    config = integration.config || %{}
    window_minutes = config["window_minutes"] || 5
    since = DateTime.add(DateTime.utc_now(), -window_minutes * 60, :second)

    total_error_count = count_errors_in_window(integration.id, since)
    window_bucket = div(System.os_time(:second), window_minutes * 60)

    error_summaries =
      new_entries
      |> Enum.filter(&(&1.severity in [:error, :critical]))
      |> Enum.take(5)
      |> Enum.map(& &1.content)
      |> Enum.map(&String.slice(&1, 0, 100))
      |> Enum.uniq()

    summary = "Top errors: #{Enum.join(error_summaries, "; ")}"

    %{
      agent_id: integration.custom_agent_id,
      event_type: :integration,
      urgency: :deferred,
      title: "#{total_error_count} errors in last #{window_minutes} minutes",
      summary: String.slice(summary, 0, 200),
      source_type: :integration,
      source_id: to_string(integration.id),
      payload: %{
        integration_id: integration.id,
        source_type: :log,
        error_count: total_error_count,
        sample_entry_ids: new_entries |> Enum.take(3) |> Enum.map(& &1.id),
        window_minutes: window_minutes
      },
      idempotency_key: "threshold:#{integration.id}:#{window_bucket}"
    }
  end

  # --- Private ---

  defp parse_single_entry(raw) do
    level = raw["level"] || extract_level_from_content(raw["message"] || "")
    severity = Map.get(@level_to_severity, String.downcase(to_string(level)), :info)

    timestamp =
      case raw["timestamp"] do
        ts when is_binary(ts) ->
          case DateTime.from_iso8601(ts) do
            {:ok, dt, _} -> dt
            _ -> DateTime.utc_now()
          end

        _ ->
          DateTime.utc_now()
      end

    metadata =
      (raw["metadata"] || %{})
      |> Map.merge(%{"level" => to_string(level)})

    %{
      content: raw["message"] || inspect(raw),
      severity: severity,
      metadata: metadata,
      occurred_at: timestamp,
      external_id: raw["id"] || raw["external_id"]
    }
  end

  defp extract_level_from_content(content) do
    cond do
      content =~ ~r/\b(ERROR|ERR)\b/i -> "error"
      content =~ ~r/\b(WARN|WARNING)\b/i -> "warning"
      content =~ ~r/\b(DEBUG)\b/i -> "debug"
      content =~ ~r/\b(CRITICAL|FATAL|EMERGENCY)\b/i -> "critical"
      true -> "info"
    end
  end

  defp crash_signature?(content) do
    Enum.any?(crash_patterns(), &Regex.match?(&1, content))
  end

  defp crash_patterns do
    [
      ~r/GenServer.*terminating/i,
      ~r/\*\*\s*\(EXIT\)/,
      ~r/SIGTERM/i,
      ~r/SIGKILL/i,
      ~r/\*\*\s*\(RuntimeError\)/,
      ~r/\*\*\s*\(FunctionClauseError\)/,
      ~r/Process.*crashed/i,
      ~r/Ranch listener.*connection process.*exit/i
    ]
  end

  defp extract_crash_title(content) do
    content |> String.slice(0, 80) |> String.trim()
  end
end
