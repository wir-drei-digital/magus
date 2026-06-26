defmodule Magus.Agents.Tools.Integrations.SearchEntries do
  @moduledoc """
  Agent tool for searching ingested data across all data sources (logs, RSS, email).
  """

  use Jido.Action,
    name: "search_ingested_data",
    description:
      "Search logs, RSS feeds, and other ingested data sources. Use this to find specific log entries, errors, RSS articles, or other ingested content.",
    schema: [
      source_type: [
        type: {:or, [{:in, [:log, :rss, :email]}, nil]},
        default: nil,
        doc: "Filter by source type"
      ],
      query: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Text search on content/title"
      ],
      severity: [
        type: {:or, [{:in, [:critical, :error, :warning, :info, :debug]}, nil]},
        default: nil,
        doc: "Filter by severity level"
      ],
      since: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Start time as ISO8601 datetime"
      ],
      until: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "End time as ISO8601 datetime"
      ],
      limit: [type: :integer, default: 20, doc: "Maximum entries to return"]
    ]

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2]

  def display_name, do: "Searching ingested data..."

  def summarize_output(%{entries: entries}) when is_list(entries),
    do: "Found #{length(entries)} entries"

  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Search completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id]) do
      {:ok, ctx} ->
        args =
          %{
            source_type: parse_atom(params["source_type"]),
            query: params["query"],
            severity: parse_atom(params["severity"]),
            since: parse_datetime(params["since"]),
            until: parse_datetime(params["until"]),
            limit: params["limit"] || 20
          }
          |> Enum.reject(fn {_k, v} -> is_nil(v) end)
          |> Map.new()

        case Magus.Integrations.list_user_ingestion_entries(ctx.user_id, args, authorize?: false) do
          {:ok, entries} ->
            formatted =
              Enum.map(entries, fn e ->
                %{
                  id: e.id,
                  source_type: e.source_type,
                  severity: e.severity,
                  title: e.title,
                  content: String.slice(e.content || "", 0, 500),
                  metadata: e.metadata,
                  occurred_at: DateTime.to_iso8601(e.occurred_at)
                }
              end)

            {:ok, %{entries: formatted}}

          {:error, reason} ->
            {:ok, %{error: "Search failed: #{inspect(reason)}"}}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  defp parse_atom(nil), do: nil
  defp parse_atom(val) when is_atom(val), do: val

  defp parse_atom(val) when is_binary(val) do
    case val do
      "log" -> :log
      "rss" -> :rss
      "email" -> :email
      "critical" -> :critical
      "error" -> :error
      "warning" -> :warning
      "info" -> :info
      "debug" -> :debug
      _ -> nil
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(val) when is_binary(val) do
    case DateTime.from_iso8601(val) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
