defmodule Magus.Agents.Actions.GenerateTitle do
  @moduledoc """
  Jido Action for generating conversation titles from message history.

  Generates short, descriptive titles (2-8 words) based on the conversation content.

  ## Usage

      {:ok, result} = GenerateTitle.run(%{
        messages: [
          %{source: :user, text: "How do I make sourdough bread?"},
          %{source: :agent, text: "Here's how to make sourdough..."}
        ]
      }, %{})

      result.text  # => "Sourdough Bread Recipe"
  """

  use Jido.Action,
    name: "generate_title",
    description: "Generate a short title for a conversation",
    schema: [
      messages: [type: {:list, :map}, required: true, doc: "Conversation messages"],
      model: [type: :string, default: nil, doc: "Model key override (defaults to title_model)"],
      user_id: [type: :string, default: nil, doc: "User ID for usage tracking"],
      conversation_id: [type: :string, default: nil, doc: "Conversation ID for usage tracking"]
    ]

  require Logger

  alias Magus.Agents.Config
  alias Magus.Agents.Persistence.UsageRecorder
  alias Magus.Agents.Clients.LLM, as: LLMClient

  @impl true
  def run(params, _context) do
    messages = params.messages
    model = params[:model] || Config.title_model()
    user_id = params[:user_id]
    conversation_id = params[:conversation_id]

    Logger.debug("GenerateTitle.run",
      model: model,
      message_count: length(messages)
    )

    context_messages =
      [ReqLLM.Context.system(system_prompt())] ++
        Enum.map(messages, fn message ->
          if message.source == :agent do
            ReqLLM.Context.assistant(message.text)
          else
            ReqLLM.Context.user(message.text)
          end
        end) ++
        [
          ReqLLM.Context.user(
            "Generate a title for this conversation with max 8 words using the language of the previous messages."
          )
        ]

    context = ReqLLM.Context.new(context_messages)

    case LLMClient.llm_client().generate_text(model, context, []) do
      {:ok, response} ->
        text = ReqLLM.Response.text(response)

        # Record usage for this system operation (non-billable)
        if user_id do
          record_usage(user_id, conversation_id, model, response.usage)
        end

        {:ok,
         %{
           text: text,
           usage: response.usage
         }}

      {:error, error} ->
        Logger.error("GenerateTitle failed", error: inspect(error))
        {:error, error}
    end
  end

  defp system_prompt do
    """
    Provide a short name for the current conversation.
    2-8 words, preferring more succinct names.
    RESPOND WITH ONLY THE NEW CONVERSATION NAME
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
      action_name: "generate_title"
    )
  end
end
