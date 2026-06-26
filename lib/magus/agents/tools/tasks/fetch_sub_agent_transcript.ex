defmodule Magus.Agents.Tools.Tasks.FetchSubAgentTranscript do
  @moduledoc """
  Returns the message + tool history of a sub-agent the parent spawned.

  Parent must specify the task_id from a prior `spawn_sub_agent` call. The
  tool authorizes by verifying `AgentRun.source_conversation_id` matches
  the calling conversation.
  """

  use Jido.Action,
    name: "fetch_sub_agent_transcript",
    description: """
    Fetch the full message + tool history of a sub-agent you spawned.

    Use when the spawn result's `result_text` and `tools_used` summary are
    not enough — for example, to inspect a specific intermediate tool call's
    output, or when the sub-agent's final response references something you
    need to verify.
    """,
    schema: [
      task_id: [
        type: :string,
        required: true,
        doc: "task_id from a prior spawn_sub_agent call."
      ],
      include: [
        type: {:list, {:in, [:messages, :tools, :files]}},
        default: [:messages, :tools],
        doc: "Sections to return."
      ],
      tail: [
        type: {:or, [:integer, nil]},
        default: nil,
        doc: "If set, return only the last N items per section. Default cap: 50."
      ]
    ]

  require Ash.Query

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2]

  alias Magus.Agents.AgentRun
  alias Magus.Agents.SubAgent.ResultEnrichment
  alias Magus.Chat.Message
  alias Magus.Chat.Message.ToolCallHelpers
  alias Magus.Agents.Support.AiAgent

  @default_cap 50

  def display_name, do: "Fetching sub-agent transcript..."

  def summarize_output(%{messages: msgs, tools: tools}) when is_list(msgs) and is_list(tools),
    do: "#{length(msgs)} message(s), #{length(tools)} tool call(s)"

  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Done"

  @impl true
  def run(params, context) do
    case validate_context(context, [:conversation_id]) do
      {:ok, ctx} ->
        task_id = get_param(params, :task_id)
        include = parse_include(get_param(params, :include))
        tail = get_param(params, :tail) || @default_cap

        case fetch_run(task_id, ctx.conversation_id) do
          {:ok, %{error: _} = error_map} ->
            {:ok, error_map}

          {:ok, run} ->
            payload = %{
              task_id: to_string(run.id),
              status: to_string(run.status),
              objective: run.objective
            }

            payload =
              if MapSet.member?(include, :messages),
                do: Map.put(payload, :messages, fetch_messages(run.target_conversation_id, tail)),
                else: payload

            payload =
              if MapSet.member?(include, :tools),
                do: Map.put(payload, :tools, fetch_tools(run.target_conversation_id, tail)),
                else: payload

            payload =
              if MapSet.member?(include, :files),
                do:
                  Map.put(
                    payload,
                    :files,
                    ResultEnrichment.files_created(run.target_conversation_id)
                  ),
                else: payload

            {:ok, payload}
        end

      {:error, message} ->
        {:ok, %{error: message}}
    end
  end

  # Normalize the `include` parameter to a MapSet of atoms.
  # The ReAct runner skips Jido's schema validation when invoking actions, so
  # `params` contains raw LLM JSON values: `["messages", "tools"]` rather than
  # `[:messages, :tools]`. Without this, `MapSet.member?(set, :messages)` would
  # return false against a set of strings and silently drop both sections.
  @valid_includes ~w(messages tools files)a

  defp parse_include(nil), do: MapSet.new([:messages, :tools])
  defp parse_include([]), do: MapSet.new([:messages, :tools])

  defp parse_include(list) when is_list(list) do
    list
    |> Enum.map(&to_include_atom/1)
    |> Enum.filter(&(&1 in @valid_includes))
    |> case do
      [] -> MapSet.new([:messages, :tools])
      atoms -> MapSet.new(atoms)
    end
  end

  defp parse_include(_), do: MapSet.new([:messages, :tools])

  defp to_include_atom(value) when is_atom(value), do: value

  defp to_include_atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp to_include_atom(_), do: nil

  defp fetch_run(task_id, parent_conv_id) do
    case AgentRun
         |> Ash.Query.filter(id == ^task_id and source_conversation_id == ^parent_conv_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, %AgentRun{} = run} -> {:ok, run}
      {:ok, nil} -> {:ok, %{error: "Sub-agent task #{task_id} not found in this conversation"}}
      {:error, _} -> {:ok, %{error: "Sub-agent task #{task_id} not found"}}
    end
  end

  defp fetch_messages(nil, _tail), do: []

  defp fetch_messages(conv_id, tail) do
    Message
    |> Ash.Query.filter(
      conversation_id == ^conv_id and
        source == :agent and
        message_type == :message and
        disabled != true
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(tail)
    |> Ash.read!(actor: %AiAgent{})
    |> Enum.reverse()
    |> Enum.map(fn msg ->
      %{
        role: "agent",
        text: msg.text || "",
        tool_calls: ToolCallHelpers.extract_tool_calls(msg.tool_call_data),
        inserted_at: msg.inserted_at
      }
    end)
  end

  defp fetch_tools(nil, _tail), do: []

  defp fetch_tools(conv_id, tail) do
    Message
    |> Ash.Query.filter(
      conversation_id == ^conv_id and
        message_type == :event and
        not is_nil(tool_call_data) and
        disabled != true
    )
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(tail)
    |> Ash.read!(actor: %AiAgent{})
    |> Enum.reverse()
    |> Enum.map(fn ev ->
      tcd = ev.tool_call_data || %{}

      %{
        tool_name: tcd["tool_name"],
        display_name: tcd["display_name"],
        inputs: tcd["inputs"],
        output_summary: tcd["output_summary"],
        status: tcd["status"]
      }
    end)
  end
end
