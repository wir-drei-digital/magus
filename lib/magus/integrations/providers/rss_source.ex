defmodule Magus.Integrations.Providers.RssSource do
  @moduledoc """
  Data source provider for RSS/Atom feed polling.

  Periodically fetches configured feed URLs, parses entries, and stores
  them as IngestionEntry records. All items get :info severity by default.

  ## Configuration (stored in UserIntegration.config)

      %{
        "feed_url" => "https://example.com/feed.xml",
        "poll_interval_minutes" => 60,
        "retention_days" => 30
      }
  """

  @behaviour Magus.Integrations.Providers.Behaviour
  @behaviour Magus.Integrations.Providers.DataSourceBehaviour

  require Logger

  # 1 MiB body size limit for RSS feeds
  @max_body_bytes 1_048_576

  # --- Base Behaviour callbacks ---

  @impl Magus.Integrations.Providers.Behaviour
  def key, do: :rss_source

  @impl Magus.Integrations.Providers.Behaviour
  def name, do: "RSS Feed"

  @impl Magus.Integrations.Providers.Behaviour
  def description, do: "Subscribe to RSS/Atom feeds for content ingestion"

  @impl Magus.Integrations.Providers.Behaviour
  def auth_type, do: :none

  @impl Magus.Integrations.Providers.Behaviour
  def source_type, do: :data_source

  @impl Magus.Integrations.Providers.Behaviour
  def operations, do: [:poll]

  @impl Magus.Integrations.Providers.Behaviour
  def execute(_operation, _credentials, _params), do: {:error, :not_supported}

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
  def parse_ingestion_payload(%{"items" => items}, _headers) when is_list(items) do
    parsed = Enum.map(items, &parse_rss_item/1)
    {:ok, parsed}
  end

  def parse_ingestion_payload(_payload, _headers) do
    {:error, {:invalid_payload, "Expected 'items' array"}}
  end

  @impl Magus.Integrations.Providers.DataSourceBehaviour
  def classify(_entry), do: %{severity: :info, title: nil}

  @impl Magus.Integrations.Providers.DataSourceBehaviour
  def should_create_inbox_event?(_integration, entries), do: entries != []

  @impl Magus.Integrations.Providers.DataSourceBehaviour
  def build_inbox_event_attrs(integration, new_entries) do
    date_bucket = Date.utc_today() |> Date.to_iso8601()

    titles =
      new_entries
      |> Enum.take(5)
      |> Enum.map(fn e -> e.title || String.slice(e.content, 0, 60) end)

    summary = Enum.join(titles, "; ")

    %{
      agent_id: integration.custom_agent_id,
      event_type: :integration,
      urgency: :deferred,
      title: "#{length(new_entries)} new items from feed",
      summary: String.slice(summary, 0, 200),
      source_type: :integration,
      source_id: to_string(integration.id),
      payload: %{
        integration_id: integration.id,
        source_type: :rss,
        new_count: length(new_entries),
        entry_ids: Enum.map(new_entries, & &1.id)
      },
      idempotency_key: "rss:#{integration.id}:#{date_bucket}"
    }
  end

  @impl Magus.Integrations.Providers.DataSourceBehaviour
  def poll(integration, _credential) do
    config = integration.config || %{}

    feed_urls =
      (config["feed_urls"] || [])
      |> Enum.reject(&(&1 == "" or is_nil(&1)))

    if feed_urls == [] do
      {:error, :no_feed_url_configured}
    else
      results =
        Enum.flat_map(feed_urls, fn url ->
          case fetch_and_parse_feed(url) do
            {:ok, items} ->
              items

            {:error, reason} ->
              Logger.warning("Failed to fetch feed #{url}: #{inspect(reason)}")
              []
          end
        end)

      {:ok, results}
    end
  end

  # --- Private ---

  defp parse_rss_item(item) do
    title = item["title"]
    link = item["link"] || item["url"]
    description = item["description"] || item["summary"] || item["content"] || ""
    author = item["author"] || item["creator"]

    timestamp =
      case item["pub_date"] || item["published"] || item["updated"] do
        ts when is_binary(ts) ->
          case DateTime.from_iso8601(ts) do
            {:ok, dt, _} -> dt
            _ -> DateTime.utc_now()
          end

        _ ->
          DateTime.utc_now()
      end

    content =
      case {title, description} do
        {nil, nil} -> nil
        {nil, d} -> d
        {t, nil} -> t
        {t, ""} -> t
        {t, d} -> "#{t}\n\n#{d}"
      end

    %{
      title: title,
      content: content,
      severity: :info,
      metadata: %{
        "url" => link,
        "author" => author,
        "published_at" => to_string(timestamp)
      },
      occurred_at: timestamp,
      external_id: link || generate_external_id(title, description)
    }
  end

  defp fetch_and_parse_feed(url) do
    case Req.get(url, receive_timeout: 15_000, decode_body: false, raw: true) do
      {:ok, %Req.Response{status: 200, body: body}} when byte_size(body) <= @max_body_bytes ->
        parse_feed_body(body)

      {:ok, %Req.Response{status: 200}} ->
        {:error, :response_too_large}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:fetch_error, reason}}
    end
  end

  defp parse_feed_body(body) when is_binary(body) do
    # Try RSS first, then Atom. Normalize to string-key maps, then
    # run through parse_rss_item/1 to produce the atom-key maps that
    # ProcessIngestion.classify_and_store expects.
    raw_items =
      case FastRSS.parse_rss(body) do
        {:ok, %{"items" => items}} when is_list(items) and items != [] ->
          {:ok, Enum.map(items, &normalize_rss_item/1)}

        _ ->
          case FastRSS.parse_atom(body) do
            {:ok, %{"entries" => entries}} when is_list(entries) and entries != [] ->
              {:ok, Enum.map(entries, &normalize_atom_entry/1)}

            {:ok, _} ->
              {:ok, []}

            {:error, reason} ->
              Logger.warning("Failed to parse feed: #{inspect(reason)}")
              {:error, {:parse_error, inspect(reason)}}
          end
      end

    case raw_items do
      {:ok, items} ->
        parsed =
          items
          |> Enum.map(&parse_rss_item/1)
          |> Enum.reject(&is_nil(&1.content))

        {:ok, parsed}

      error ->
        error
    end
  end

  defp normalize_rss_item(item) do
    %{
      "title" => item["title"],
      "link" => item["link"],
      "description" => item["description"] || item["content"],
      "pub_date" => item["pub_date"],
      "author" =>
        item["author"] ||
          get_in(item, ["dublin_core_ext", "creator"]) |> List.wrap() |> List.first()
    }
  end

  defp normalize_atom_entry(entry) do
    link =
      case entry["links"] do
        [%{"href" => href} | _] -> href
        _ -> nil
      end

    %{
      "title" => entry["title"] && entry["title"]["value"],
      "link" => link,
      "description" =>
        (entry["summary"] && entry["summary"]["value"]) ||
          (entry["content"] && entry["content"]["value"]),
      "published" => entry["published"] || entry["updated"],
      "author" =>
        case entry["authors"] do
          [%{"name" => name} | _] -> name
          _ -> nil
        end
    }
  end

  defp generate_external_id(title, description) do
    content = "#{title}#{description}"
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower) |> String.slice(0, 16)
  end
end
