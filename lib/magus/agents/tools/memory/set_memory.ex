defmodule Magus.Agents.Tools.Memory.SetMemory do
  @moduledoc """
  Tool for creating or updating a memory by name (upsert).

  When a user explicitly asks the model to remember something, this tool
  allows the model to immediately persist that information rather than
  waiting for the background extraction pipeline.
  """

  use Jido.Action,
    name: "set_memory",
    description: """
    Create or update a named memory. Use this when the user explicitly asks you to remember something.

    SCOPE determines where the memory lives:
    - "user" (default): User-wide preferences, facts, and settings that apply everywhere.
      Examples: "Remember I prefer TypeScript", "My timezone is CET".
    - "local": Conversation-specific context that only matters here.
      Examples: "Remember the deadline is Friday", "Note we chose option B".
    - "agent": Custom-agent-scoped memories, only available to a specific agent.

    If a memory with the same name already exists in the given scope, it will be updated.
    """,
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "Short, descriptive name for the memory (e.g. 'preferred_language')"
      ],
      summary: [
        type: :string,
        required: true,
        doc: "Human-readable summary of what is being remembered"
      ],
      content: [
        type: :map,
        required: false,
        default: %{},
        doc: "Structured key-value data to store"
      ],
      scope: [
        type: :string,
        required: false,
        default: "user",
        doc: "Memory scope: 'local', 'user', or 'agent'"
      ],
      confidence: [
        type: {:or, [:float, nil]},
        default: nil,
        doc: "Confidence score 0.0-1.0"
      ],
      kind: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "Memory kind: general, fact, hypothesis, observation, summary, preference, goal, topic, habit, reflection"
      ],
      structured_data: [
        type: {:or, [:map, nil]},
        default: nil,
        doc: "Structured metadata for the memory kind (e.g., deadlines, streaks, sources)"
      ]
    ]

  require Logger

  alias Magus.Memory

  import Magus.Agents.Tools.Memory.Helpers,
    only: [
      validate_context: 2,
      validate_scope: 1,
      find_memory_by_name: 3,
      ai_actor: 0,
      enforce_global_write_isolation: 2
    ]

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_param: 3]

  def display_name, do: "Saving memory..."

  def summarize_output(%{status: "created", name: name}), do: "Created '#{name}'"
  def summarize_output(%{status: "updated", name: name}), do: "Updated '#{name}'"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    scope = get_param(params, :scope, "user")

    with {:ok, scope} <- validate_scope(scope),
         {:ok, scope} <- enforce_global_write_isolation(scope, context) do
      required_fields =
        case scope do
          "user" -> [:user_id]
          "agent" -> [:user_id, :custom_agent_id]
          _ -> [:user_id, :conversation_id]
        end

      case validate_context(context, required_fields) do
        {:ok, ctx} ->
          name = get_param(params, :name)
          summary = get_param(params, :summary)
          content = get_param(params, :content, %{}) |> ensure_map()

          confidence = get_param(params, :confidence)
          kind = get_param(params, :kind)
          structured_data = get_param(params, :structured_data)
          extra_attrs = build_extra_attrs(confidence, kind, structured_data)

          upsert_memory(name, summary, content, scope, ctx, extra_attrs)

        {:error, message} ->
          {:ok, %{error: message}}
      end
    else
      {:error, message} -> {:ok, %{error: message}}
    end
  end

  defp upsert_memory(name, summary, content, scope, ctx, extra_attrs) do
    case find_memory_by_name(name, scope, ctx) do
      {:ok, memory} ->
        update_memory(memory, name, summary, content, extra_attrs)

      {:error, :not_found} ->
        create_memory(name, summary, content, scope, ctx, extra_attrs)

      {:error, error} ->
        Logger.warning("SetMemory: lookup failed - #{inspect(error)}")
        {:ok, %{error: "Failed to look up memory: #{inspect(error)}"}}
    end
  end

  defp update_memory(memory, name, summary, content, extra_attrs) do
    merged = Map.merge(memory.content || %{}, content)
    attrs = Map.merge(%{summary: summary}, extra_attrs)

    case Memory.set_memory(memory, merged, attrs, actor: ai_actor()) do
      {:ok, _updated} ->
        Logger.debug("SetMemory: updated '#{name}'")
        {:ok, %{status: "updated", name: name, summary: summary}}

      {:error, error} ->
        Logger.warning("SetMemory: update failed - #{inspect(error)}")
        {:ok, %{error: "Failed to update memory: #{inspect(error)}"}}
    end
  end

  defp create_memory(name, summary, content, "user", ctx, extra_attrs) do
    attrs = Map.merge(%{content: content, summary: summary}, extra_attrs)
    workspace_id = Map.get(ctx, :workspace_id)

    case Memory.create_user_memory(
           ctx.user_id,
           workspace_id,
           name,
           attrs,
           actor: ai_actor()
         ) do
      {:ok, _memory} ->
        Logger.debug("SetMemory: created global memory '#{name}'")
        {:ok, %{status: "created", name: name, scope: "user", summary: summary}}

      {:error, error} ->
        Logger.warning("SetMemory: create failed - #{inspect(error)}")
        {:ok, %{error: "Failed to create memory: #{inspect(error)}"}}
    end
  end

  defp create_memory(name, summary, content, "agent", ctx, extra_attrs) do
    attrs = Map.merge(%{content: content, summary: summary}, extra_attrs)

    case Memory.create_agent_memory(
           ctx.user_id,
           ctx.custom_agent_id,
           Map.put(attrs, :name, name),
           actor: ai_actor()
         ) do
      {:ok, _memory} ->
        Logger.debug("SetMemory: created agent memory '#{name}'")
        {:ok, %{status: "created", name: name, scope: "agent", summary: summary}}

      {:error, error} ->
        Logger.warning("SetMemory: create failed - #{inspect(error)}")
        {:ok, %{error: "Failed to create memory: #{inspect(error)}"}}
    end
  end

  defp create_memory(name, summary, content, _local, ctx, extra_attrs) do
    attrs = Map.merge(%{content: content, summary: summary}, extra_attrs)

    case Memory.create_memory(
           ctx.conversation_id,
           ctx.user_id,
           name,
           attrs,
           actor: ai_actor()
         ) do
      {:ok, _memory} ->
        Logger.debug("SetMemory: created local memory '#{name}'")
        {:ok, %{status: "created", name: name, scope: "local", summary: summary}}

      {:error, error} ->
        Logger.warning("SetMemory: create failed - #{inspect(error)}")
        {:ok, %{error: "Failed to create memory: #{inspect(error)}"}}
    end
  end

  @valid_kinds ~w(general fact hypothesis observation summary preference goal topic habit reflection)

  defp build_extra_attrs(confidence, kind, structured_data) do
    %{}
    |> then(fn attrs ->
      if confidence, do: Map.put(attrs, :confidence, confidence), else: attrs
    end)
    |> then(fn attrs ->
      if kind && kind in @valid_kinds,
        do: Map.put(attrs, :kind, String.to_existing_atom(kind)),
        else: attrs
    end)
    |> then(fn attrs ->
      if structured_data, do: Map.put(attrs, :structured_data, structured_data), else: attrs
    end)
  end

  defp ensure_map(value) when is_map(value), do: value

  defp ensure_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  defp ensure_map(_), do: %{}
end
