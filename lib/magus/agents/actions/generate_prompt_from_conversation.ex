defmodule Magus.Agents.Actions.GeneratePromptFromConversation do
  @moduledoc """
  Jido Action for generating a reusable prompt from conversation patterns.

  Analyzes conversation messages to extract key behaviors, styles, and patterns
  that can be captured in a reusable prompt.

  ## Usage

      {:ok, result} = GeneratePromptFromConversation.run(%{
        messages: [
          %{source: :user, text: "Can you explain this like I'm 5?"},
          %{source: :agent, text: "Sure! Let me break this down simply..."}
        ]
      }, %{})

      result.content        # => "Explain concepts in simple terms..."
      result.suggested_type # => :format
      result.suggested_name # => "Simple Explanations"
  """

  use Jido.Action,
    name: "generate_prompt_from_conversation",
    description: "Generates a reusable prompt from conversation patterns",
    schema: [
      messages: [type: {:list, :map}, required: true, doc: "Conversation messages"],
      model: [type: :string, default: nil, doc: "Model key override (defaults to summary_model)"],
      user_id: [type: :string, default: nil, doc: "User ID for usage tracking"],
      conversation_id: [type: :string, default: nil, doc: "Conversation ID for usage tracking"]
    ]

  require Logger

  alias Magus.Agents.Config
  alias Magus.Agents.Persistence.UsageRecorder
  alias Magus.Agents.Clients.LLM, as: LLMClient

  @output_schema [
    content: [type: :string, required: true, doc: "The reusable prompt/instruction text"],
    suggested_type: [
      type: :string,
      required: true,
      doc: "Type of prompt: system (for AI behavior/persona) or user (for reusable content)"
    ],
    suggested_name: [type: :string, required: true, doc: "Short name for the prompt (2-5 words)"]
  ]

  @impl true
  def run(params, _context) do
    messages = params.messages
    model = params[:model] || Config.summary_model()
    user_id = params[:user_id]
    conversation_id = params[:conversation_id]

    Logger.debug("GeneratePromptFromConversation.run",
      model: model,
      message_count: length(messages)
    )

    prompt = build_prompt(messages)

    case LLMClient.llm_client().generate_object(model, prompt, @output_schema,
           system_prompt: system_prompt()
         ) do
      {:ok, response} ->
        result = response.object
        suggested_type = parse_type(result["suggested_type"])

        # Record usage for this system operation (non-billable)
        if user_id do
          record_usage(user_id, conversation_id, model, response.usage)
        end

        {:ok,
         %{
           content: result["content"],
           suggested_type: suggested_type,
           suggested_name: result["suggested_name"],
           usage: response.usage
         }}

      {:error, error} ->
        Logger.error("GeneratePromptFromConversation failed", error: inspect(error))
        {:error, error}
    end
  end

  defp build_prompt(messages) do
    conversation_text =
      messages
      |> Enum.map(fn msg ->
        role = if msg.source == :agent, do: "Assistant", else: "User"
        "#{role}: #{msg.text}"
      end)
      |> Enum.join("\n\n")

    """
    Analyze this conversation and generate a reusable prompt that captures the key patterns, behaviors, or styles demonstrated.

    ## Conversation:
    #{conversation_text}

    ## Instructions:
    Create a clear, reusable instruction that captures the essence of what made this conversation effective.
    The prompt should be written as an instruction to the AI, not a description.
    Keep it concise but comprehensive (2-4 sentences typically).
    Keep the prompt in the same language as the conversation.
    """
  end

  # Map AI suggestions to valid prompt types
  # "system" type is for AI behavior, persona, or instruction prompts
  # "user" type is for reusable content, queries, or templates
  defp parse_type("system"), do: :system
  defp parse_type("persona"), do: :system
  defp parse_type("user"), do: :user
  defp parse_type("task"), do: :user
  defp parse_type("format"), do: :user
  defp parse_type("context"), do: :user
  defp parse_type("query"), do: :user
  defp parse_type("command"), do: :user
  defp parse_type(_), do: :user

  defp system_prompt do
    """
    You are an expert at analyzing conversations and extracting reusable patterns.

    Types of prompts:
    - system: Describes AI behavior, persona, role, or how the AI should respond. Use this for instructions that define the AI's character or approach.
    - user: Reusable content, templates, tasks, formats, or queries. Use this for content the user wants to insert or reference.

    Choose "system" if the pattern is about how the AI should behave or respond.
    Choose "user" if the pattern is about specific content, tasks, or templates.
    """
  end

  defp record_usage(user_id, conversation_id, model_key, usage) do
    UsageRecorder.record!(
      user_id: user_id,
      conversation_id: conversation_id,
      model_key: model_key,
      usage: usage,
      usage_type: :response,
      billable: false,
      action_name: "generate_prompt"
    )
  end
end
