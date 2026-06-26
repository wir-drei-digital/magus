defmodule Magus.Agents.Actions.GenerateText do
  @moduledoc """
  Generic LLM text generation action using ReqLLM.

  This is a simple, reusable action for making LLM calls. It handles:
  - Streaming text generation
  - Tool specification (but NOT tool execution - that's the caller's responsibility)
  - Sampling parameters (temperature, max_tokens, etc.)

  The agentic loop (tool execution, iteration) is NOT handled here - that belongs
  in the strategy layer (ReAct.Strategy + composable plugins).

  ## Usage

      # Simple text generation
      {:ok, result} = GenerateText.run(%{
        model: "openrouter:google/gemini-2.5-flash",
        messages: context
      }, %{})

      # With tools (tools are passed to LLM but NOT executed)
      {:ok, result} = GenerateText.run(%{
        model: "openrouter:google/gemini-2.5-flash",
        messages: context,
        tools: reqllm_tools,
        temperature: 0.7
      }, %{})

  ## Result

      %{
        text: "Generated response text",
        tool_calls: [%{id: "...", name: "...", arguments: %{}}],
        usage: %{input_tokens: 100, output_tokens: 50},
        chunks: [%ReqLLM.StreamChunk{}, ...]
      }

  The caller is responsible for:
  - Executing tool calls if present
  - Adding tool results to context
  - Calling GenerateText again if continuing the loop
  """

  use Jido.Action,
    name: "generate_text",
    description: "Generate streaming text response from an LLM",
    schema: [
      model: [
        type: :string,
        required: true,
        doc: "Model spec string (e.g., 'openrouter:google/gemini-2.5-flash')"
      ],
      messages: [
        type: :any,
        required: true,
        doc: "ReqLLM.Context or list of messages"
      ],
      tools: [
        type: {:list, :any},
        default: [],
        doc: "ReqLLM.Tool structs to pass to the LLM"
      ],
      temperature: [type: :float, default: nil, doc: "Sampling temperature (0.0-2.0)"],
      max_tokens: [type: :pos_integer, default: nil, doc: "Maximum tokens to generate"],
      top_p: [type: :float, default: nil, doc: "Nucleus sampling parameter (0.0-1.0)"],
      top_k: [type: :pos_integer, default: nil, doc: "Top-k sampling parameter"],
      on_chunk: [
        type: :any,
        default: nil,
        doc:
          "Optional callback function called for each chunk: fn chunk, accumulated_text -> :ok end"
      ]
    ]

  require Logger

  alias Magus.Agents.Support.ToolsHelper
  alias Magus.Agents.Clients.LLM, as: LLMClient
  alias ReqLLM.StreamResponse

  @doc """
  Struct used as an Ash actor for system-level operations.
  """
  defstruct []

  @impl true
  def run(params, _context) do
    model = params.model
    messages = params.messages
    tools = params[:tools] || []
    on_chunk = params[:on_chunk]

    # Build options
    opts =
      []
      |> maybe_add_opt(:tools, if(tools != [], do: tools, else: nil))
      |> maybe_add_opt(:temperature, params[:temperature])
      |> maybe_add_opt(:max_tokens, params[:max_tokens])
      |> maybe_add_opt(:top_p, params[:top_p])
      |> maybe_add_opt(:top_k, params[:top_k])

    Logger.debug("GenerateText: streaming",
      model: model,
      tool_count: length(tools)
    )

    case LLMClient.llm_client().stream_text(model, messages, opts) do
      {:ok, stream_response} ->
        {text, chunks} = process_stream(stream_response, on_chunk)
        tool_calls = ToolsHelper.extract_tool_calls_from_chunks(chunks)
        usage = StreamResponse.usage(stream_response)

        {:ok,
         %{
           text: text,
           tool_calls: tool_calls,
           usage: usage,
           chunks: chunks
         }}

      {:error, error} ->
        Logger.error("GenerateText: stream failed", error: inspect(error))
        {:error, error}
    end
  end

  @doc """
  Build ReqLLM Tool structs from Jido Action modules.

  This is a utility function that can be used by strategies or other callers
  to convert Jido Action modules into ReqLLM Tool structs.

  ## Example

      tools = GenerateText.build_tools_from_actions(
        [DiceRoll, WebSearch],
        %{WebSearch => %{user_id: user_id}}
      )
  """
  @spec build_tools_from_actions([module()], map()) :: [ReqLLM.Tool.t()]
  def build_tools_from_actions([], _tool_contexts), do: []

  def build_tools_from_actions(action_modules, tool_contexts) do
    Enum.map(action_modules, fn module ->
      context = Map.get(tool_contexts, module)

      ReqLLM.Tool.new!(
        name: module.name(),
        description: module.description(),
        parameter_schema: module.schema(),
        callback: fn args -> module.run(args, context) end
      )
    end)
  end

  # Process the stream, collecting chunks and text
  # Optionally calls on_chunk callback for each chunk
  defp process_stream(stream_response, on_chunk) do
    stream_response.stream
    |> Enum.reduce({[], ""}, fn chunk, {chunks_acc, text_acc} ->
      new_text_acc =
        if chunk.type == :content do
          accumulated = text_acc <> chunk.text

          # Call optional callback
          if on_chunk, do: on_chunk.(chunk, accumulated)

          accumulated
        else
          text_acc
        end

      {[chunk | chunks_acc], new_text_acc}
    end)
    |> then(fn {chunks, text} -> {text, Enum.reverse(chunks)} end)
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
