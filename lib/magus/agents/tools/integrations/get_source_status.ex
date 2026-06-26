defmodule Magus.Agents.Tools.Integrations.GetSourceStatus do
  @moduledoc """
  Agent tool for getting a summary of data source health and activity.
  """

  use Jido.Action,
    name: "get_source_status",
    description:
      "Get a summary of recent activity from your ingested data sources (logs, RSS feeds). Shows entry counts, error rates, and last activity time per source.",
    schema: [
      source_type: [
        type: {:or, [{:in, [:log, :rss, :email]}, nil]},
        default: nil,
        doc: "Filter by source type"
      ]
    ]

  require Ash.Query

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  def display_name, do: "Checking source status..."

  def summarize_output(%{sources: sources}) when is_list(sources),
    do: "#{length(sources)} source(s) reporting"

  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Status check completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id]) do
      {:ok, ctx} ->
        one_hour_ago = DateTime.add(DateTime.utc_now(), -3600, :second)

        case Magus.Integrations.list_user_integrations(ctx.user_id, authorize?: false) do
          {:ok, integrations} ->
            source_type_filter = parse_atom(params["source_type"])

            sources =
              integrations
              |> Enum.filter(&(&1.status == :active))
              |> Enum.filter(fn int ->
                provider_mod = Magus.Integrations.get_provider_module(int.provider_key)
                provider_mod && function_exported?(provider_mod, :parse_ingestion_payload, 2)
              end)
              |> Enum.map(fn int ->
                source_type = integration_source_type(int)

                if source_type_filter && source_type != source_type_filter do
                  nil
                else
                  build_source_summary(int, source_type, one_hour_ago)
                end
              end)
              |> Enum.reject(&is_nil/1)

            {:ok, %{sources: sources}}

          {:error, reason} ->
            {:ok, %{error: "Failed to fetch sources: #{inspect(reason)}"}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp build_source_summary(integration, source_type, since) do
    total =
      case Magus.Integrations.IngestionEntry
           |> Ash.Query.for_read(:for_integration, %{
             user_integration_id: integration.id,
             since: since
           })
           |> Ash.count(authorize?: false) do
        {:ok, count} -> count
        _ -> 0
      end

    error_count =
      case Magus.Integrations.count_ingestion_entries_by_severity(
             integration.id,
             :error,
             since,
             authorize?: false
           ) do
        {:ok, count} -> count
        _ -> 0
      end

    %{
      integration_id: integration.id,
      source_type: source_type,
      provider_key: integration.provider_key,
      total_entries: total,
      error_count: error_count,
      last_sync_at: integration.last_sync_at && DateTime.to_iso8601(integration.last_sync_at),
      config:
        Map.take(integration.config || %{}, [
          "feed_url",
          "error_threshold",
          "window_minutes"
        ])
    }
  end

  defp integration_source_type(integration) do
    case integration.provider_key do
      :log_source -> :log
      :rss_source -> :rss
      _ -> :unknown
    end
  end

  defp parse_atom(nil), do: nil
  defp parse_atom(val) when is_atom(val), do: val

  defp parse_atom(val) when is_binary(val) do
    case val do
      "log" -> :log
      "rss" -> :rss
      "email" -> :email
      _ -> nil
    end
  end
end
