defmodule Magus.Models.CatalogSync do
  @moduledoc """
  Builds the LLMDB `:custom` provider/model map from DB rows (Provider +
  Magus.Chat.Model) and reloads LLMDB at runtime.

  Replaces the old boot-time `config :llm_db, :custom` coupling: model/
  provider changes take effect without restart.

  This module contains the pure build logic; the reload GenServer wraps it.
  """

  # Default base URLs for req_llm providers we register custom entries for.
  # nil means "let ReqLLM's provider module default apply" — only providers
  # whose LLMDB entry needs an explicit base_url are listed.
  @known_base_urls %{
    "openrouter" => "https://openrouter.ai/api/v1",
    "publicai" => "https://api.publicai.co/v1"
  }

  @doc """
  Returns the LLMDB `:custom` map: `%{provider_atom => [name:, base_url:, models: %{id => entry}]}`.

  Only enabled providers and active, provider-linked models are included.
  """
  @spec build_custom() :: map()
  def build_custom do
    # Global providers only: owned (BYOK) providers carry a user-minted slug
    # and must never reach slug_to_atom/1's atom creation. Dropping them here
    # also drops their models below, since the models filter keys off this map.
    providers =
      Magus.Models.list_enabled_providers!(authorize?: false)
      |> Enum.filter(&is_nil(&1.owner_user_id))
      |> Map.new(&{&1.id, &1})

    models =
      Magus.Chat.list_provider_linked_active_models!(authorize?: false)
      |> Enum.filter(&Map.has_key?(providers, &1.model_provider_id))

    models
    |> Enum.group_by(& &1.model_provider_id)
    |> Map.new(fn {provider_id, provider_models} ->
      provider = providers[provider_id]

      {slug_to_atom(provider.slug),
       [
         name: provider.name,
         base_url: provider.base_url || Map.get(@known_base_urls, provider.req_llm_id),
         models: Map.new(provider_models, &{model_id(&1, provider), entry(&1)})
       ]}
    end)
  end

  # LLMDB keys custom providers by atom. Slugs are NOT user input: Provider
  # writes require an admin actor (see Magus.Models.Provider policies) and
  # the set is bounded by rows in model_providers, so atom creation here is
  # bounded by deliberate admin actions. Prefer the existing atom (all
  # built-in provider slugs already exist as atoms via the catalog); only a
  # brand-new admin-created slug allocates one new atom.
  defp slug_to_atom(slug) do
    String.to_existing_atom(slug)
  rescue
    ArgumentError -> :erlang.binary_to_atom(slug, :utf8)
  end

  # "openrouter:anthropic/claude-x" with slug "openrouter" -> "anthropic/claude-x"
  defp model_id(model, provider) do
    String.replace_prefix(model.key, provider.slug <> ":", "")
  end

  defp entry(model) do
    meta = model.llm_metadata || %{}

    if meta["simple_capabilities"] do
      %{capabilities: %{chat: true, stream: true}}
    else
      %{
        name: model.name,
        capabilities: capabilities(model, meta),
        cost: cost(model, meta),
        limits: limits(model, meta),
        modalities: modalities(model, meta)
      }
    end
  end

  defp capabilities(model, meta) do
    base =
      if meta["simple_streaming"] do
        %{chat: true, stream: true}
      else
        %{chat: true, streaming: %{tool_calls: true}}
      end

    base
    |> maybe_put_tools(meta)
    |> maybe_put_reasoning(model, meta)
  end

  defp maybe_put_tools(caps, meta) do
    if meta["skip_tools"] || meta["simple_streaming"],
      do: caps,
      else: Map.put(caps, :tools, %{enabled: true})
  end

  defp maybe_put_reasoning(caps, model, meta) do
    cond do
      meta["skip_reasoning"] -> caps
      meta["simple_streaming"] -> caps
      model.supports_reasoning? -> Map.put(caps, :reasoning, %{enabled: true})
      true -> caps
    end
  end

  defp cost(model, meta) do
    %{
      input: meta["input_cost"] || decimal_to_float(model.input_cost_value),
      output: meta["output_cost"] || decimal_to_float(model.output_cost_value)
    }
    |> maybe_put(:cache_read, meta["cache_read"])
    |> maybe_put(:cache_write, meta["cache_write"])
  end

  defp limits(model, meta) do
    %{
      context: context_limit(model, meta),
      output: output_limit(meta)
    }
  end

  # LLMDB requires context >= 1 (Zoi.min(1)) and raises otherwise. Both
  # inputs are admin-controlled and unconstrained: `context_window` is
  # nullable/unbounded and `meta["context"]` is free-form JSON. Clamp to a
  # valid positive integer so a malformed row can never make LLMDB.load raise.
  defp context_limit(model, meta) do
    base =
      case meta["context"] do
        n when is_integer(n) and n > 0 -> n
        _ -> model.context_window || 1
      end

    max(base, 1)
  end

  # LLMDB requires output >= 1 too; `meta["output_limit"]` is free-form JSON,
  # so clamp it the same way (default 32_000 when absent/invalid).
  defp output_limit(meta) do
    case meta["output_limit"] do
      n when is_integer(n) and n > 0 -> n
      _ -> 32_000
    end
  end

  defp modalities(model, meta) do
    %{
      input: atomize(meta["input_modalities"] || model.input_modalities || ["text"]),
      output: atomize(meta["output_modalities"] || model.output_modalities || ["text"])
    }
  end

  # Drop modalities that don't resolve to a known atom, then guarantee a
  # non-empty list: a model whose only modalities were unknown still gets a
  # valid `[:text]` rather than `[]`.
  defp atomize(list) do
    case list |> Enum.map(&modality_atom/1) |> Enum.reject(&is_nil/1) do
      [] -> [:text]
      atoms -> atoms
    end
  end

  # Modalities are a small closed set. LLMDB only accepts its pre-registered
  # modality atoms, so an admin-settable modality string that maps to no
  # existing atom can never be a valid LLMDB modality anyway: drop it
  # (returning nil) instead of raising or minting a fresh atom that LLMDB
  # would reject downstream.
  defp modality_atom(value) when is_atom(value), do: value

  defp modality_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp decimal_to_float(%Decimal{} = d), do: Decimal.to_float(d)
  defp decimal_to_float(n) when is_number(n), do: n / 1
  defp decimal_to_float(nil), do: 0.0

  @doc """
  Synchronously rebuilds the custom map and reloads LLMDB.

  `snapshot_source` is taken from the `:snapshot_source` option when given,
  otherwise read from `config :magus, :llm_db_snapshot_source` (default:
  LLMDB's packaged snapshot); set to `{:github_releases, ref: :latest}` to
  pull the newest published registry at reload time (falls back to packaged
  on fetch failure inside LLMDB's loader). The per-call option lets the admin
  "Refresh registry" button request a fresh fetch without changing app config.
  """
  @spec reload(keyword()) :: :ok | {:error, term()}
  def reload(opts \\ []) do
    load_opts = [custom: build_custom()]

    snapshot_source =
      Keyword.get(opts, :snapshot_source) ||
        Application.get_env(:magus, :llm_db_snapshot_source)

    load_opts =
      if snapshot_source,
        do: Keyword.put(load_opts, :snapshot_source, snapshot_source),
        else: load_opts

    with {:ok, _snapshot} <- LLMDB.load(load_opts), do: :ok
  end

  @doc """
  Runs `reload/1` inside a broad rescue + `catch :exit` boundary, always
  returning `:ok | {:error, reason}` (never raising).

  `LLMDB.load` swaps the whole catalog and its Zoi schema raises
  `ArgumentError` on a malformed overlay (e.g. context < 1); a pool-checkout
  `:exit` can also escape. This is a data/transport problem, not a reason to
  crash the caller (the serializing `Server`, or the admin refresh task). The
  packaged/previous catalog stays in place and the reason is returned for the
  caller to log or surface.

  This is the single guarded reload shared by both the cast path
  (`Server.handle_info(:do_reload)`, which logs the result) and the manual
  refresh path (`Server.refresh/2`, which returns it for a flash) — there is
  no second rescue elsewhere.
  """
  @spec guarded_reload(keyword()) :: :ok | {:error, term()}
  def guarded_reload(opts \\ []) do
    case reload(opts) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    # Deliberately rescue *any* exception so bad catalog data leaves the
    # packaged catalog in place instead of taking the caller down. The
    # error + stacktrace are returned (and logged by callers) so genuine
    # code bugs (UndefinedFunctionError, KeyError, …) stay visible.
    error ->
      {:error, Exception.format(:error, error, __STACKTRACE__)}
  catch
    # A pool-checkout exit (pool shutdown, sandbox owner gone) shouldn't kill
    # the caller either; degrade and report like Roles.assignment/1.
    :exit, reason ->
      {:error, {:exit, reason}}
  end

  @doc "Asynchronous reload via the serializing server (no-op if not running)."
  @spec request_reload() :: :ok
  def request_reload do
    case Process.whereis(Magus.Models.CatalogSync.Server) do
      nil -> :ok
      pid -> GenServer.cast(pid, :reload)
    end
  end
end
