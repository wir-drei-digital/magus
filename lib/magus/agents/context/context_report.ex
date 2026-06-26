defmodule Magus.Agents.Context.ContextReport do
  @moduledoc """
  Pure context-size accounting: split an assembled system prompt into sections,
  estimate tokens (chars/4), and serialize tool schemas. Shared by
  `mix agent.preflight` and the runtime `ContextPlugin`.
  """
  alias Magus.Agents.Actions.GenerateText
  alias Magus.Agents.Context.SectionMarker

  @section_separator "\n\n---\n\n"
  @stable_prefix_marker "## Scheduling"

  # The scheduling block is the last section of the cacheable stable prefix.
  # Marked sections identify it by category; the heading is the legacy fallback.
  @stable_prefix_category :time

  @type snapshot :: %{
          categories: [%{key: atom(), label: binary(), tokens: non_neg_integer()}],
          total_tokens: non_neg_integer(),
          stable_prefix_tokens: non_neg_integer(),
          dynamic_suffix_tokens: non_neg_integer(),
          model_key: binary() | nil,
          max_context: pos_integer()
        }

  @spec build(map()) :: snapshot()
  def build(%{system_prompt: sp, tools: tools, messages: messages} = args) do
    sp = sp || ""
    {_tool_lines, tools_tokens} = tool_token_breakdown(tools || [])
    msg_tokens = messages |> Enum.map(&message_tokens/1) |> Enum.sum()
    {prefix, suffix} = prefix_suffix_split(sp)

    section_cats =
      sp
      |> split_sections()
      |> Enum.map(fn {label, tokens} -> {categorize(label), label, tokens} end)
      |> Enum.group_by(fn {key, _l, _t} -> key end, fn {_k, _l, t} -> t end)
      |> Enum.map(fn {key, toks} ->
        %{key: key, label: label_for(key), tokens: Enum.sum(toks)}
      end)

    categories =
      section_cats ++
        [
          %{key: :tools, label: "Tools", tokens: tools_tokens},
          %{key: :messages, label: "Messages", tokens: msg_tokens}
        ]

    categories = Enum.reject(categories, &(&1.tokens == 0))

    %{
      categories: categories,
      total_tokens: Enum.reduce(categories, 0, &(&1.tokens + &2)),
      stable_prefix_tokens: prefix,
      dynamic_suffix_tokens: suffix,
      model_key: args[:model_key],
      max_context: args[:max_context] || 128_000
    }
  end

  @spec approx_tokens(binary() | any()) :: non_neg_integer()
  def approx_tokens(text) when is_binary(text), do: div(String.length(text), 4)
  def approx_tokens(_), do: 0

  @spec split_sections(binary()) :: [{binary(), non_neg_integer()}]
  def split_sections(prompt) when is_binary(prompt) do
    prompt
    |> String.split(@section_separator)
    |> Enum.map(fn s -> {section_label(s), approx_tokens(s)} end)
  end

  @spec prefix_suffix_split(binary()) :: {non_neg_integer(), non_neg_integer()}
  def prefix_suffix_split(prompt) when is_binary(prompt) do
    sections = String.split(prompt, @section_separator)

    case Enum.find_index(sections, &stable_prefix_section?/1) do
      nil ->
        {approx_tokens(prompt), 0}

      idx ->
        {prefix, suffix} = Enum.split(sections, idx + 1)

        {prefix |> Enum.join(@section_separator) |> approx_tokens(),
         suffix |> Enum.join(@section_separator) |> approx_tokens()}
    end
  end

  @doc """
  Whether the assembled system prompt contains the stable-prefix boundary
  section (the scheduling block — `<!--ctx:time-->` marker, or the legacy
  `## Scheduling` heading). When absent, `prefix_suffix_split/1` treats the whole
  prompt as the stable prefix.
  """
  @spec has_stable_prefix_marker?(binary()) :: boolean()
  def has_stable_prefix_marker?(prompt) when is_binary(prompt) do
    prompt
    |> String.split(@section_separator)
    |> Enum.any?(&stable_prefix_section?/1)
  end

  # The scheduling section marks the prefix/suffix boundary. Prefer the explicit
  # category marker; fall back to the bare heading for unmarked prompts (tests,
  # legacy callers).
  defp stable_prefix_section?(section) do
    label = section_label(section)
    SectionMarker.category(label) == @stable_prefix_category or label == @stable_prefix_marker
  end

  @spec tool_token_breakdown([module() | map()]) ::
          {[{binary(), non_neg_integer()}], non_neg_integer()}
  def tool_token_breakdown(tools) do
    modules = Enum.filter(tools, &is_atom/1)
    req_tools = GenerateText.build_tools_from_actions(modules, %{})

    lines =
      req_tools
      |> Enum.map(fn t -> {t.name, approx_tokens(serialize_tool(t))} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    {lines, lines |> Enum.map(&elem(&1, 1)) |> Enum.sum()}
  end

  defp serialize_tool(%ReqLLM.Tool{} = tool) do
    case Jason.encode(ReqLLM.Tool.to_json_schema(tool)) do
      {:ok, json} ->
        json

      {:error, _} ->
        Jason.encode!(%{
          name: tool.name,
          description: tool.description,
          parameters: inspect(tool.parameter_schema)
        })
    end
  end

  defp message_tokens(%{content: c}) when is_binary(c), do: approx_tokens(c)

  defp message_tokens(%{content: parts}) when is_list(parts) do
    parts |> Enum.map(&part_text/1) |> Enum.map(&approx_tokens/1) |> Enum.sum()
  end

  defp message_tokens(_), do: 0

  defp part_text(%{text: t}) when is_binary(t), do: t
  defp part_text(t) when is_binary(t), do: t
  defp part_text(_), do: ""

  # Map a section's first line to a category. Our sections carry an explicit
  # `<!--ctx:key-->` marker (SectionMarker), which is authoritative; only
  # genuinely unmarked content falls through to the heading heuristics below.
  defp categorize(label) do
    SectionMarker.category(label) || categorize_by_heading(label)
  end

  # Legacy/defensive fallback for UNMARKED sections: guess the category from the
  # heading. Kept so an accidentally-unmarked section still gets a best-effort
  # row rather than always landing in :other_system. The match phrases are
  # specific (e.g. "available agents") to avoid swallowing arbitrary custom
  # content, which has no fixed heading and genuinely belongs in :other_system.
  # Order matters: the first matching clause wins.
  defp categorize_by_heading(label) do
    l = String.downcase(label)

    cond do
      String.contains?(l, "summary of earlier") -> :summary
      String.contains?(l, "skill") -> :skills
      String.contains?(l, "orchestrat") -> :orchestration
      String.contains?(l, "available agents") -> :agents
      String.contains?(l, "available api") -> :apis
      String.contains?(l, ["current time", "scheduling"]) -> :time
      String.contains?(l, ["memory", "memories"]) -> :memory
      String.contains?(l, ["relevant files", "from your files", "file context"]) -> :files_rag
      String.contains?(l, "super") and String.contains?(l, ["brain", "page"]) -> :super_brain
      String.contains?(l, ["brain", "page", "companion"]) -> :brain
      String.contains?(l, "active workspace") -> :workspace
      String.contains?(l, ["active draft", "## drafts"]) -> :drafts
      String.contains?(l, "active jobs") -> :jobs
      String.contains?(l, "## tasks") -> :tasks
      String.contains?(l, ["attached_documents", "attached documents"]) -> :documents
      String.contains?(l, ["persona", "you are", "base", "your name is"]) -> :persona
      String.contains?(l, ["instruction", "custom"]) -> :instructions
      true -> :other_system
    end
  end

  defp label_for(:wakeup), do: "Wake-up"
  defp label_for(:companion), do: "Companion"
  defp label_for(:tool_hint), do: "Tool hint"
  defp label_for(:skills), do: "Skills index"
  defp label_for(:orchestration), do: "Orchestration"
  defp label_for(:agents), do: "Agents"
  defp label_for(:apis), do: "APIs"
  defp label_for(:time), do: "Time"
  defp label_for(:memory), do: "Memory"
  defp label_for(:files_rag), do: "Files (RAG)"
  defp label_for(:brain), do: "Brain"
  defp label_for(:super_brain), do: "Super Brain"
  defp label_for(:workspace), do: "Workspace"
  defp label_for(:drafts), do: "Drafts"
  defp label_for(:jobs), do: "Jobs"
  defp label_for(:tasks), do: "Tasks"
  defp label_for(:documents), do: "Attached documents"
  defp label_for(:persona), do: "Persona / base rules"
  defp label_for(:instructions), do: "Instructions"
  defp label_for(:summary), do: "Summary"
  defp label_for(:other_system), do: "Other (system)"

  # Defensive: a marker naming an existing-but-unlabeled category humanizes
  # rather than crashing the breakdown (e.g. "files_rag" -> "Files rag").
  defp label_for(other) when is_atom(other),
    do: other |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp section_label(section) do
    section
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
    |> case do
      nil -> "(empty)"
      line -> String.slice(line, 0, 40)
    end
  end
end
