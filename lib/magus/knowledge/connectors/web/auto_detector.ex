defmodule Magus.Knowledge.Connectors.Web.AutoDetector do
  @moduledoc """
  Probes a seed URL to auto-detect the best discovery strategy.

  Detection order:
  1. GET seed URL — if JSON and looks like OpenAPI spec → `Strategies.OpenApi`
  2. HEAD `{origin}/sitemap.xml` — if 200 → `Strategies.Sitemap`
  3. Fallback → `Strategies.LinkFollow`

  Also fetches `{origin}/robots.txt` to extract robots rules and crawl-delay.
  """

  require Logger

  alias Magus.Knowledge.Connectors.Web.Strategies

  @doc """
  Probes `seed_url` and returns `{:ok, strategy_module, robots_rules, crawl_delay_ms}`.

  Detection order:
  1. GET seed URL — if JSON body looks like an OpenAPI spec → `Strategies.OpenApi`
  2. HEAD `{origin}/sitemap.xml` — if 200 → `Strategies.Sitemap`
  3. Fallback → `Strategies.LinkFollow`

  `robots_rules` and `crawl_delay_ms` are parsed from `{origin}/robots.txt`.
  `crawl_delay_ms` is `nil` when no crawl-delay directive is found.
  """
  @spec detect(String.t(), list()) ::
          {:ok, module(), list(), non_neg_integer() | nil} | {:error, term()}
  def detect(seed_url, auth_headers \\ []) do
    origin = extract_origin(seed_url)
    headers = normalize_headers(auth_headers)

    {robots_rules, _sitemap_urls, crawl_delay_ms} =
      fetch_robots_txt(origin, headers)

    strategy = detect_strategy(seed_url, origin, headers)

    {:ok, strategy, robots_rules, crawl_delay_ms}
  end

  @doc """
  Returns the strategy module for an explicit strategy override string, or `nil` for `"auto"`.

  Recognized values: `"auto"`, `"sitemap"`, `"openapi"`, `"pagination"`, `"link_follow"`.
  Any unrecognized value returns `nil`.
  """
  @spec strategy_for_override(String.t()) :: module() | nil
  def strategy_for_override("auto"), do: nil
  def strategy_for_override("sitemap"), do: Strategies.Sitemap
  def strategy_for_override("openapi"), do: Strategies.OpenApi
  def strategy_for_override("pagination"), do: Strategies.Pagination
  def strategy_for_override("link_follow"), do: Strategies.LinkFollow
  def strategy_for_override(_), do: nil

  @doc """
  Returns `true` if `body` is a map containing an `"openapi"` or `"swagger"` key.
  """
  @spec is_openapi_spec?(term()) :: boolean()
  def is_openapi_spec?(body) when is_map(body) do
    Map.has_key?(body, "openapi") or Map.has_key?(body, "swagger")
  end

  def is_openapi_spec?(_), do: false

  @doc """
  Parses robots.txt content into a list of rule structs.

  Returns `[%{user_agent: String.t(), disallow: [String.t()]}]`.
  """
  @spec parse_robots_txt(String.t()) :: [%{user_agent: String.t(), disallow: [String.t()]}]
  def parse_robots_txt(content) when is_binary(content) do
    {rules, _sitemaps, _crawl_delay} = parse_robots_txt_full(content)
    rules
  end

  @doc """
  Parses robots.txt content and returns `{rules, sitemap_urls}`.
  """
  @spec parse_robots_txt_with_sitemaps(String.t()) ::
          {[%{user_agent: String.t(), disallow: [String.t()]}], [String.t()]}
  def parse_robots_txt_with_sitemaps(content) when is_binary(content) do
    {rules, sitemaps, _crawl_delay} = parse_robots_txt_full(content)
    {rules, sitemaps}
  end

  @doc """
  Parses robots.txt content and returns `{rules, sitemap_urls, crawl_delay_ms}`.

  The crawl-delay is taken from the wildcard (`*`) user-agent block if present,
  otherwise from the first block that specifies one. Returns `nil` when absent.

  Crawl-delay is converted from seconds to milliseconds (e.g. `"2"` → `2000`,
  `"0.5"` → `500`).
  """
  @spec parse_robots_txt_full(String.t()) ::
          {[%{user_agent: String.t(), disallow: [String.t()]}], [String.t()],
           non_neg_integer() | nil}
  def parse_robots_txt_full(content) when is_binary(content) do
    lines =
      content
      |> String.replace("\r\n", "\n")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))

    {rules, sitemaps, crawl_delays} = parse_lines(lines)

    # Prefer crawl-delay from wildcard block; otherwise take the first found
    crawl_delay_ms =
      case Map.get(crawl_delays, "*") || Enum.at(Map.values(crawl_delays), 0) do
        nil -> nil
        seconds -> round(seconds * 1000)
      end

    {rules, sitemaps, crawl_delay_ms}
  end

  # --- Private helpers ---

  @doc false
  @spec extract_origin(String.t()) :: String.t()
  def extract_origin(url) when is_binary(url) do
    uri = URI.parse(url)

    port_part =
      if uri.port && uri.port != URI.default_port(uri.scheme) do
        ":#{uri.port}"
      else
        ""
      end

    "#{uri.scheme}://#{uri.host}#{port_part}"
  end

  defp detect_strategy(seed_url, origin, headers) do
    with false <- openapi_at_seed?(seed_url, headers),
         false <- sitemap_exists?(origin, headers) do
      Strategies.LinkFollow
    else
      {:openapi, true} -> Strategies.OpenApi
      {:sitemap, true} -> Strategies.Sitemap
    end
  end

  defp openapi_at_seed?(url, headers) do
    case Req.get(url, headers: headers, receive_timeout: 15_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        parsed =
          cond do
            is_map(body) ->
              body

            is_binary(body) ->
              case Jason.decode(body) do
                {:ok, decoded} -> decoded
                {:error, _} -> nil
              end

            true ->
              nil
          end

        if parsed && is_openapi_spec?(parsed) do
          {:openapi, true}
        else
          false
        end

      _ ->
        false
    end
  end

  defp sitemap_exists?(origin, headers) do
    sitemap_url = "#{origin}/sitemap.xml"

    case Req.head(sitemap_url, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: 200}} -> {:sitemap, true}
      _ -> false
    end
  end

  defp fetch_robots_txt(origin, headers) do
    robots_url = "#{origin}/robots.txt"

    case Req.get(robots_url, headers: headers, receive_timeout: 10_000) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        content = if is_binary(body), do: body, else: to_string(body)
        parse_robots_txt_full(content)

      _ ->
        {[], [], nil}
    end
  end

  defp parse_lines(lines) do
    # State: current_agents accumulates user-agents for the current block
    initial = %{
      current_agents: [],
      disallows: [],
      crawl_delay: nil,
      rules: [],
      sitemaps: [],
      crawl_delays: %{}
    }

    state =
      Enum.reduce(lines, initial, fn line, acc ->
        cond do
          String.starts_with?(line, "User-agent:") ->
            value = parse_directive_value(line, "User-agent:")

            # If we already have disallows/crawl-delay and encounter a new User-agent
            # after an empty line would have flushed, we need to handle continuation.
            # A new User-agent: line either starts a fresh block or continues current.
            # Flush if we have disallows buffered with a current agent that differs.
            if acc.current_agents == [] do
              %{acc | current_agents: [value]}
            else
              # Check if this is a continuation (stacked user-agents) or new block.
              # New block means disallows were already accumulated — flush first.
              if acc.disallows != [] or acc.crawl_delay != nil do
                acc
                |> flush_block()
                |> Map.put(:current_agents, [value])
              else
                %{acc | current_agents: acc.current_agents ++ [value]}
              end
            end

          String.starts_with?(line, "Disallow:") ->
            value = parse_directive_value(line, "Disallow:")

            if value == "" do
              acc
            else
              %{acc | disallows: acc.disallows ++ [value]}
            end

          String.starts_with?(line, "Allow:") ->
            acc

          String.starts_with?(line, "Crawl-delay:") ->
            value = parse_directive_value(line, "Crawl-delay:")

            case Float.parse(value) do
              {seconds, _} -> %{acc | crawl_delay: seconds}
              :error -> acc
            end

          String.starts_with?(line, "Sitemap:") ->
            value = parse_directive_value(line, "Sitemap:")

            if value != "" do
              %{acc | sitemaps: acc.sitemaps ++ [value]}
            else
              acc
            end

          true ->
            acc
        end
      end)

    # Flush final block
    final = flush_block(state)

    {final.rules, final.sitemaps, final.crawl_delays}
  end

  defp flush_block(%{current_agents: []} = state), do: state

  defp flush_block(state) do
    %{current_agents: agents, disallows: disallows, crawl_delay: crawl_delay} = state

    new_rules =
      Enum.map(agents, fn agent ->
        %{user_agent: agent, disallow: disallows}
      end)

    new_crawl_delays =
      if crawl_delay do
        Enum.reduce(agents, state.crawl_delays, fn agent, acc ->
          Map.put_new(acc, agent, crawl_delay)
        end)
      else
        state.crawl_delays
      end

    %{
      state
      | current_agents: [],
        disallows: [],
        crawl_delay: nil,
        rules: state.rules ++ new_rules,
        crawl_delays: new_crawl_delays
    }
  end

  defp parse_directive_value(line, prefix) do
    line
    |> String.slice(String.length(prefix)..-1//1)
    |> String.trim()
  end

  defp normalize_headers(headers) when is_list(headers), do: headers
  defp normalize_headers(_), do: []
end
