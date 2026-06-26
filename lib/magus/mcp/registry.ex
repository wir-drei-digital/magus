defmodule Magus.MCP.Registry do
  @moduledoc """
  Read-only client over the official public MCP registry
  (`registry.modelcontextprotocol.io`), with a small in-process TTL cache.

  The registry is a public catalog of MCP servers. This module fetches it,
  filters to **importable remote servers** (see `Magus.MCP.RegistryEntry`), and
  normalizes each into a `%RegistryEntry{}`. The SvelteKit settings page reaches
  it through `MagusWeb.Rpc.McpRegistryController`; never the browser directly, so
  filtering/normalization happen once and the catalog can later be swapped for a
  self-hosted registry or an aggregator via `:registry_base_url`.

  The base URL is fixed config (not user input), so it is not subject to SSRF
  validation; the *imported* server's URL still passes `Magus.MCP.SafeUrl`.
  """

  use GenServer

  require Logger

  alias Magus.MCP.RegistryEntry

  @table :mcp_registry_cache
  @default_base_url "https://registry.modelcontextprotocol.io"
  @default_ttl_ms :timer.minutes(60)
  @default_limit 30
  @request_timeout_ms 8_000

  # ── Public API ──────────────────────────────────────────────────────────────

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Lists registry servers, filtered to importable remote servers.

  Options: `:search` (substring on name), `:cursor` (opaque pagination token),
  `:limit`. Returns `{:ok, %{entries: [RegistryEntry.t()], next_cursor: String.t() | nil}}`
  or `{:error, reason}`. Results are cached per query for `:registry_cache_ttl_ms`.
  """
  @spec list(keyword()) ::
          {:ok, %{entries: [RegistryEntry.t()], next_cursor: String.t() | nil}} | {:error, term()}
  def list(opts \\ []) do
    key = {:list, opts[:search], opts[:cursor], opts[:limit]}

    with_cache(key, fn -> fetch_list(opts) end)
  end

  @doc """
  Fetches a single server by its registry name (reverse-DNS id) and version
  (`"latest"` by default). Returns `{:ok, RegistryEntry.t()}`, `{:error, :not_remote}`
  for a packages-only/stdio server, or `{:error, reason}`.
  """
  @spec get(String.t(), String.t()) :: {:ok, RegistryEntry.t()} | {:error, term()}
  def get(registry_name, version \\ "latest") do
    with_cache({:get, registry_name, version}, fn -> fetch_get(registry_name, version) end)
  end

  # ── GenServer (owns the ETS cache table) ─────────────────────────────────────

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  # ── Cache ────────────────────────────────────────────────────────────────────

  defp with_cache(key, fun) do
    now = System.monotonic_time(:millisecond)

    case lookup(key, now) do
      {:ok, value} ->
        {:ok, value}

      :miss ->
        case fun.() do
          {:ok, value} ->
            :ets.insert(@table, {key, value, now + ttl_ms()})
            {:ok, value}

          {:error, _} = err ->
            err
        end
    end
  end

  defp lookup(key, now) do
    case :ets.lookup(@table, key) do
      [{^key, value, expires_at}] when expires_at > now -> {:ok, value}
      _ -> :miss
    end
  rescue
    # Table may not exist yet in unit tests that don't start the GenServer.
    ArgumentError -> :miss
  end

  # ── Fetching ─────────────────────────────────────────────────────────────────

  defp fetch_list(opts) do
    params =
      [
        search: opts[:search],
        cursor: opts[:cursor],
        limit: opts[:limit] || @default_limit
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) or v == "" end)

    case request(:get, "/v0/servers", params) do
      {:ok, body} ->
        entries =
          body
          |> Map.get("servers", [])
          |> dedup_to_latest()
          |> Enum.flat_map(fn raw ->
            case RegistryEntry.from_raw(raw) do
              {:ok, entry} -> [entry]
              :skip -> []
            end
          end)

        {:ok, %{entries: entries, next_cursor: next_cursor(body)}}

      {:error, _} = err ->
        err
    end
  end

  # The registry lists every published version of a server as its own entry
  # (same `name`, different `version`), with `_meta…isLatest` marking the current
  # one. Collapse to one raw entry per name — preferring the latest — so the
  # catalog shows a single card per server and downstream keys (`registry_name`)
  # stay unique (a duplicate key crashes the keyed list in the SPA). First-seen
  # order is preserved; nameless entries are dropped (not importable).
  defp dedup_to_latest(servers) when is_list(servers) do
    chosen =
      Enum.reduce(servers, %{}, fn raw, acc ->
        case raw_name(raw) do
          nil ->
            acc

          name ->
            if raw_latest?(raw) or not Map.has_key?(acc, name),
              do: Map.put(acc, name, raw),
              else: acc
        end
      end)

    servers
    |> Enum.map(&raw_name/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.map(&Map.fetch!(chosen, &1))
  end

  defp dedup_to_latest(_), do: []

  defp raw_name(raw) when is_map(raw) do
    if is_map(raw["server"]), do: raw["server"]["name"], else: raw["name"]
  end

  defp raw_name(_), do: nil

  defp raw_latest?(raw) do
    meta = raw["_meta"] || get_in(raw, ["server", "_meta"]) || %{}
    get_in(meta, ["io.modelcontextprotocol.registry/official", "isLatest"]) == true
  end

  defp fetch_get(registry_name, version) do
    path = "/v0/servers/#{URI.encode_www_form(registry_name)}"
    params = if version in [nil, "", "latest"], do: [], else: [version: version]

    case request(:get, path, params) do
      {:ok, body} ->
        case RegistryEntry.from_raw(body) do
          {:ok, entry} -> {:ok, entry}
          :skip -> {:error, :not_remote}
        end

      {:error, _} = err ->
        err
    end
  end

  defp next_cursor(body) do
    meta = body["metadata"] || %{}
    meta["nextCursor"] || meta["next_cursor"]
  end

  defp request(:get, path, params) do
    url = base_url() <> path

    case Req.get(url, params: params, receive_timeout: @request_timeout_ms, retry: :transient) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 and is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("MCP registry returned HTTP #{status} for #{path}")
        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("MCP registry request failed for #{path}: #{inspect(reason)}")
        {:error, :registry_unavailable}
    end
  end

  # ── Config ───────────────────────────────────────────────────────────────────

  defp base_url do
    config()[:registry_base_url] || @default_base_url
  end

  defp ttl_ms do
    config()[:registry_cache_ttl_ms] || @default_ttl_ms
  end

  defp config, do: Application.get_env(:magus, Magus.MCP, [])
end
