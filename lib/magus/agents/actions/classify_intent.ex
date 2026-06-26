defmodule Magus.Agents.Actions.ClassifyIntent do
  @moduledoc """
  Jido Action for classifying message intent using an LLM.

  Uses a small LLM (Ministral 8B via OpenRouter) for zero-shot intent classification.
  Greetings and explicit search mode are handled as fast paths without an LLM call.
  When the LLM is unavailable or not configured, defaults to `:chat`.

  Complexity estimation is always heuristic (based on message length and structure).

  ## Usage

      {:ok, result} = ClassifyIntent.run(%{text: "Help me debug this function"}, %{})
      result.classification  # => %Classification{intent: :coding, ...}
  """

  use Jido.Action,
    name: "classify_intent",
    description: "Classify a user message into intent and complexity for auto-routing",
    schema: [
      text: [type: :string, required: true, doc: "The user message text to classify"],
      mode: [
        type: {:in, [:chat, :search, :reasoning, :image_generation, :video_generation]},
        default: :chat,
        doc: "Current chat mode (:search overrides intent detection)"
      ],
      metadata: [
        type: :map,
        default: %{},
        doc: "Message metadata (pdf_selection, service_selection, etc.)"
      ],
      user_id: [type: {:or, [:string, nil]}, default: nil, doc: "User ID for usage recording"],
      conversation_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Conversation ID for usage recording"
      ]
    ]

  require Logger

  alias Magus.Agents.Routing.AutoRouter.Classification
  alias Magus.Agents.Clients.LLM, as: LLMClient
  alias Magus.Agents.Config
  alias Magus.Agents.Persistence.UsageRecorder

  # ============================================================================
  # LLM classification schema
  # ============================================================================

  @classification_schema %{
    "type" => "object",
    "properties" => %{
      "intent" => %{
        "type" => "string",
        "enum" => ["coding", "search", "reasoning", "creative", "chat"]
      },
      "confidence" => %{"type" => "number"}
    },
    "required" => ["intent", "confidence"]
  }

  @classification_system_prompt """
  Classify the user message intent. Return JSON with "intent" and "confidence" (0-1).

  Intents:
  - coding: programming, debugging, code review, technical implementation, generate a document (latex, excel, pdf)
  - search: needs current/real-time info, news, weather, prices, recent events
  - reasoning: math, logic, proofs, analysis, academic problems
  - creative: stories, poems, essays, creative content
  - chat: general conversation, opinions, advice, everything else
  """

  @valid_intents ~w(coding search reasoning creative chat)a

  # ============================================================================
  # Jido Action callback
  # ============================================================================

  @impl true
  def run(params, _context) do
    text = params.text
    mode = params[:mode] || :chat
    metadata = params[:metadata] || %{}

    classification =
      cond do
        mode == :search ->
          %Classification{
            intent: :search,
            complexity: estimate_complexity(text),
            confidence: 1.0,
            method: :heuristic
          }

        has_coding_metadata?(metadata) ->
          %Classification{
            intent: :coding,
            complexity: estimate_complexity(text),
            confidence: 0.95,
            method: :heuristic
          }

        greeting?(text) ->
          %Classification{
            intent: :chat,
            complexity: :simple,
            confidence: 0.95,
            method: :heuristic
          }

        true ->
          classify_with_llm(text, params)
      end

    {:ok, %{classification: classification}}
  end

  # ============================================================================
  # LLM classification
  # ============================================================================

  defp classify_with_llm(text, params) do
    model = Config.classification_model()

    if is_nil(model) do
      Logger.debug("No classification model configured, defaulting to chat")
      default_classification(text)
    else
      call_llm(text, model, params)
    end
  end

  defp call_llm(text, model, params) do
    case LLMClient.llm_client().generate_object(
           model,
           text,
           @classification_schema,
           system_prompt: @classification_system_prompt
         ) do
      {:ok, response} ->
        maybe_record_usage(model, response.usage || %{}, params)
        parse_llm_response(response.object, text)

      {:error, reason} ->
        Logger.warning("LLM classification failed, defaulting to chat: #{inspect(reason)}")
        default_classification(text)
    end
  end

  defp default_classification(text) do
    %Classification{
      intent: :chat,
      complexity: estimate_complexity(text),
      confidence: 0.0,
      method: :heuristic
    }
  end

  defp parse_llm_response(object, text) when is_map(object) do
    intent = parse_intent(object["intent"])
    confidence = parse_confidence(object["confidence"])

    %Classification{
      intent: intent,
      complexity: estimate_complexity(text),
      confidence: confidence,
      method: :llm
    }
  end

  defp parse_llm_response(_object, text) do
    Logger.warning("LLM classification returned unexpected format, defaulting to chat")
    default_classification(text)
  end

  defp parse_intent(intent) when is_binary(intent) do
    atom = String.to_existing_atom(intent)
    if atom in @valid_intents, do: atom, else: :chat
  rescue
    ArgumentError -> :chat
  end

  defp parse_intent(_), do: :chat

  defp parse_confidence(confidence) when is_number(confidence) do
    confidence |> max(0.0) |> min(1.0)
  end

  defp parse_confidence(_), do: 0.5

  defp maybe_record_usage(model, usage, params) do
    if params[:user_id] do
      UsageRecorder.record!(
        user_id: params.user_id,
        conversation_id: params[:conversation_id],
        model_key: model,
        usage: usage,
        usage_type: :response,
        billable: false,
        action_name: "classify_intent"
      )
    end
  end

  # ============================================================================
  # Complexity estimation
  # ============================================================================

  defp estimate_complexity(text) do
    length = String.length(text)
    word_count = text |> String.split(~r/\s+/, trim: true) |> length()

    signals =
      [
        String.graphemes(text) |> Enum.count(&(&1 == "?")) > 1,
        Regex.match?(~r/^\s*[\d•\-\*]+[.)]\s/m, text),
        String.contains?(text, "```"),
        word_count > 100,
        text |> String.split(~r/\n\s*\n/, trim: true) |> length() > 2
      ]
      |> Enum.count(& &1)

    cond do
      length < 30 and signals == 0 -> :simple
      signals >= 3 or word_count > 200 -> :hard
      signals >= 1 or word_count > 50 -> :medium
      true -> :simple
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp has_coding_metadata?(metadata) do
    Map.has_key?(metadata, "pdf_selection") or Map.has_key?(metadata, "service_selection")
  end

  defp greeting?(text) do
    greeting_patterns = [
      ~r/^(h(i|ey|ello|allo|owdy)|yo|sup|what'?s up|good (morning|afternoon|evening))[\s!?.]*$/i,
      ~r/^(hallo|moin|servus|grüß (dich|gott)|guten (tag|morgen|abend)|na|hey)[\s!?.]*$/i,
      ~r/^(salut|bonjour|bonsoir|coucou|ça va)[\s!?.]*$/i,
      ~r/^(thanks?|thank you|danke|merci|thx|ty)[\s!?.]*$/i
    ]

    Enum.any?(greeting_patterns, &Regex.match?(&1, String.trim(String.downcase(text))))
  end
end
