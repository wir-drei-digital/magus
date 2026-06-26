defmodule Magus.Agents.Tools.Catalog do
  @moduledoc """
  The searchable universe of tools the agent can discover and load on demand.

  Entries are scored by keyword overlap against a query. Resolving a tool name
  back to its module reuses `Magus.Agents.Tools.ToolBuilder.skill_tool_mapping/0`
  so the catalog and the skills system agree on the name to module map.

  Internal tools plus actor-scoped MCP tools. The `Entry` shape is
  source-pluggable: `source: :internal` resolves to a module, `source:
  {:mcp, server_id}` resolves to a `ReqLLM.Tool` carrier built from the
  registered server's cached tool definitions. See the spec at
  `docs/superpowers/specs/2026-06-16-tool-search-dynamic-loading-design.md`.

  ## Actor scoping (the single MCP access checkpoint)

  MCP entries and resolution are gated by `context[:user]` (a real `%User{}`).
  The actor's accessible servers are read through `Magus.MCP.list_accessible_servers/1`
  (the primary `:read`, actor-scoped by `workspace_scoped_policies`), so a server
  that is not shared with the actor never surfaces a tool. Coined names are
  recovered to `(server_id, remote_name)` ONLY by reverse lookup against that
  actor-scoped set, never by splitting the name on `__`.
  """

  require Logger

  alias Magus.Accounts.User
  alias Magus.Agents.Tools.ToolBuilder
  alias Magus.MCP
  alias Magus.MCP.ToolAdapter

  alias Magus.Agents.Tools.DiceRoll
  alias Magus.Agents.Tools.Models.ListModels
  alias Magus.Agents.Tools.Library.{ListPrompts, CreatePrompt}
  alias Magus.Agents.Tools.Threads.CreateThread
  alias Magus.Agents.Tools.Media.{GenerateImage, GenerateVideo}

  defmodule Entry do
    @moduledoc "A single searchable tool in the catalog."
    @enforce_keys [:name, :description, :category, :keywords, :source, :resolver]
    defstruct [:name, :description, :category, :keywords, :source, :resolver]
  end

  # Discoverable internal tools: module => extra keywords beyond name/description.
  # These tools are intentionally NOT in the always-on base set; the agent finds
  # them with tool_search and enables them with load_tool.
  @searchable %{
    DiceRoll => ~w(dice die roll random chance d20 coin flip),
    GenerateImage => ~w(image picture illustration draw render art photo logo),
    GenerateVideo => ~w(video clip animation movie render footage),
    ListModels => ~w(model models llm available capabilities which),
    ListPrompts => ~w(prompt prompts library templates saved),
    CreatePrompt => ~w(prompt save store library template reusable),
    CreateThread => ~w(thread branch fork side spinoff)
  }

  # Query tokens that carry no search signal.
  @stopwords ~w(the a an to in on my of for and or with put add can you me some please)

  @doc "All searchable internal catalog entries (static-only shim)."
  @spec entries() :: [Entry.t()]
  def entries, do: entries(%{})

  @doc """
  All searchable catalog entries. With `context[:user]` set to a `%User{}`, this
  appends one `{:mcp, server_id}` entry per cached tool of every server the actor
  can read. Without a user, only internal entries are returned.
  """
  @spec entries(map()) :: [Entry.t()]
  def entries(context) when is_map(context) do
    internal_entries() ++ mcp_entries(context)
  end

  defp internal_entries do
    categories = ToolBuilder.tool_to_category()

    Enum.map(@searchable, fn {module, keywords} ->
      %Entry{
        name: module.name(),
        description: module.description(),
        category: Map.get(categories, module, :general),
        keywords: keywords,
        source: :internal,
        resolver: module
      }
    end)
  end

  # Enumerate the actor's accessible MCP servers and coin one Entry per cached
  # tool. Scoped by `actor: user` -- the single MCP access checkpoint.
  defp mcp_entries(%{user: %User{} = user}) do
    case MCP.list_accessible_servers(actor: user) do
      {:ok, servers} ->
        servers
        |> Enum.filter(& &1.enabled?)
        |> Enum.flat_map(fn server ->
          (server.cached_tools || [])
          |> Enum.map(fn cached ->
            coined = ToolAdapter.coin_tool_name(server.handle, cached["name"] || "")

            %Entry{
              name: coined,
              description: cached["description"] || "",
              category: :mcp,
              keywords: mcp_keywords(server, cached),
              source: {:mcp, server.id},
              resolver: {:mcp, server.id, cached["name"]}
            }
          end)
        end)

      _ ->
        []
    end
  end

  defp mcp_entries(_), do: []

  defp mcp_keywords(server, cached) do
    [server.handle, server.name, cached["name"] || ""]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  @doc """
  Search the catalog by keyword. Returns up to `:limit` (default 5) entries
  ranked highest score first, dropping zero-score entries. `:exclude` is a list
  of tool-name strings to omit (for example, already-loaded tools). `:context`
  is a map that may carry a `%User{}` under `:user`; when present, the actor's
  MCP tools are searched alongside internal tools.
  """
  @spec search(String.t(), keyword()) :: [Entry.t()]
  def search(query, opts \\ []) do
    context = Keyword.get(opts, :context, %{})
    limit = Keyword.get(opts, :limit, 5)
    exclude = MapSet.new(Keyword.get(opts, :exclude, []))
    tokens = tokenize(query)

    entries(context)
    |> Enum.reject(&MapSet.member?(exclude, &1.name))
    |> Enum.map(fn entry -> {score(entry, tokens), entry} end)
    |> Enum.filter(fn {score, _} -> score > 0 end)
    |> Enum.sort_by(fn {score, _} -> score end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {_, entry} -> entry end)
  end

  @doc """
  Resolve tool-name strings to internal modules. Returns `{modules, unknown_names}`.

  Static-only back-compat shim: `%{}` context yields no MCP tools, so MCP names
  fall through to `unknown`. Existing callers that destructure a 2-tuple keep
  working unchanged; MCP-aware callers use `resolve/2`.
  """
  @spec resolve([String.t()]) :: {[module()], [String.t()]}
  def resolve(names) when is_list(names) do
    {modules, _mcp_tools, unknown} = resolve(names, %{})
    {modules, unknown}
  end

  def resolve(_), do: {[], []}

  @doc """
  Resolve tool-name strings against internal tools AND the actor's MCP tools.
  Returns `{modules, mcp_tools, unknown}` where `mcp_tools` is a list of Task-1
  carrier entries (`%{coined_name:, tool: %ReqLLM.Tool{}, server_id:, remote_name:}`).

  MCP names are recovered by reverse lookup against the actor's accessible servers'
  cached tools (a `coined_name => carrier` index), never by splitting on `__`.
  Names that no longer resolve (server un-shared, tool removed) go to `unknown`.
  """
  @spec resolve([String.t()], map()) :: {[module()], [map()], [String.t()]}
  def resolve(names, context) when is_list(names) and is_map(context) do
    mapping = ToolBuilder.skill_tool_mapping()
    mcp_index = mcp_resolution_index(context)

    {modules, mcp_tools, unknown} =
      Enum.reduce(names, {[], [], []}, fn name, {mods, mcps, unk} ->
        cond do
          Map.has_key?(mapping, name) ->
            {[Map.fetch!(mapping, name) | mods], mcps, unk}

          Map.has_key?(mcp_index, name) ->
            {mods, [Map.fetch!(mcp_index, name) | mcps], unk}

          true ->
            {mods, mcps, [name | unk]}
        end
      end)

    {modules |> Enum.reverse() |> Enum.uniq(), mcp_tools |> Enum.reverse() |> dedup_mcp(),
     Enum.reverse(unknown)}
  end

  def resolve(_, _), do: {[], [], []}

  # Map coined_name => carrier entry, built ONLY from the actor's accessible
  # servers' cached_tools. Reverse lookup, never name-splitting on "__".
  defp mcp_resolution_index(%{user: %User{} = user} = context) do
    case MCP.list_accessible_servers(actor: user) do
      {:ok, servers} ->
        executor_ctx = Map.take(context, [:user, :conversation_id, :user_id])

        servers
        |> Enum.filter(& &1.enabled?)
        |> Enum.flat_map(fn server ->
          (server.cached_tools || [])
          |> Enum.flat_map(fn cached ->
            case ToolAdapter.to_reqllm_tool(cached, server, executor_ctx) do
              {:ok, entry} ->
                [{entry.coined_name, entry}]

              {:error, reason} ->
                Logger.warning("Skipping MCP tool #{inspect(cached["name"])}: #{inspect(reason)}")
                []
            end
          end)
        end)
        |> Map.new()

      _ ->
        %{}
    end
  end

  defp mcp_resolution_index(_), do: %{}

  # Keep the first entry on a cross-server coined-name collision (acceptable for
  # Phase 2; cross-server disambiguation suffix is a Phase 5 polish item).
  defp dedup_mcp(entries) do
    Enum.uniq_by(entries, & &1.coined_name)
  end

  @doc """
  Build a contextual hint for the incoming message, or nil when nothing relevant
  is hidden. `available_modules` is the list of tool modules already loaded this
  turn; those are excluded so we never nudge for a tool the agent already has.

  Static-only shim: delegates to `hint_for/3` with `%{}` context.
  """
  @spec hint_for(String.t() | nil, [module()]) :: String.t() | nil
  def hint_for(text, available_modules), do: hint_for(text, available_modules, %{})

  @doc """
  Build a contextual hint, scoping the search by `context` (which may carry a
  `%User{}` under `:user` to include MCP tools). Returns nil when nothing
  relevant is hidden.
  """
  @spec hint_for(String.t() | nil, [module()], map()) :: String.t() | nil
  def hint_for(nil, _available_modules, _context), do: nil

  def hint_for(text, available_modules, context) do
    available_names =
      available_modules
      |> Enum.map(&safe_name/1)
      |> Enum.reject(&is_nil/1)

    case search(text, exclude: available_names, limit: 3, context: context) do
      [] ->
        nil

      matches ->
        names = matches |> Enum.map(& &1.name) |> Enum.join(", ")

        "Tools matching this request may be available via tool_search: #{names}. " <>
          "Call tool_search to find the right tool, then load_tool to enable it."
    end
  end

  # --- scoring ---

  defp score(%Entry{} = entry, query_tokens) do
    name_tokens = tokenize(entry.name)
    keyword_tokens = Enum.flat_map(entry.keywords, &tokenize/1)
    desc_tokens = tokenize(entry.description)
    category_tokens = tokenize(to_string(entry.category))

    Enum.reduce(query_tokens, 0, fn t, acc ->
      cond do
        t in name_tokens -> acc + 5
        t in keyword_tokens -> acc + 4
        t in category_tokens -> acc + 3
        t in desc_tokens -> acc + 1
        true -> acc
      end
    end)
  end

  defp tokenize(nil), do: []

  defp tokenize(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in @stopwords))
  end

  defp safe_name(module) when is_atom(module) do
    if function_exported?(module, :name, 0), do: module.name(), else: nil
  end

  defp safe_name(_), do: nil
end
