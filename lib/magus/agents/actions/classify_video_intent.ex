defmodule Magus.Agents.Actions.ClassifyVideoIntent do
  @moduledoc """
  Classifies video generation intent as text-to-video or image-to-video.

  Analyzes the user message and recent conversation context to determine:
  - Whether the user wants to generate video from text or from an existing image
  - If image-to-video, which image they're referencing (attachment or conversation history)

  Uses an LLM for classification when available. Falls back to heuristic
  (check for direct image attachments) when no LLM is configured.
  """

  use Jido.Action,
    name: "classify_video_intent",
    description: "Classify video generation intent as text-to-video or image-to-video",
    schema: [
      text: [type: {:or, [:string, nil]}, default: nil, doc: "The user message text"],
      conversation_context: [
        type: {:list, :map},
        default: [],
        doc: "Recent conversation messages with attachments"
      ],
      user_id: [type: {:or, [:string, nil]}, default: nil, doc: "User ID for usage recording"],
      conversation_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Conversation ID for usage recording"
      ]
    ]

  require Logger

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
        "enum" => ["text_to_video", "image_to_video"]
      },
      "source_image_url" => %{
        "type" => ["string", "null"],
        "description" => "URL of the referenced image if image_to_video, null otherwise"
      },
      "confidence" => %{"type" => "number"}
    },
    "required" => ["intent", "confidence"]
  }

  @classification_system_prompt """
  You are classifying a video generation request. Analyze the user's message and conversation context.

  Return JSON with:
  - "intent": "text_to_video" or "image_to_video"
  - "source_image_url": The URL of the image the user wants to animate (null if text_to_video)
  - "confidence": 0-1

  Classify as "image_to_video" when:
  - The user explicitly references an image ("animate this image", "make this move", "turn this into a video")
  - The user refers to a previously generated or shared image in the conversation
  - There is an image attachment in the current message

  Classify as "text_to_video" when:
  - The user describes a scene to generate from scratch
  - No image reference is present
  """

  # ============================================================================
  # Jido Action callback
  # ============================================================================

  @impl true
  def run(params, _context) do
    text = params[:text] || ""
    context = params[:conversation_context] || []

    # Fast path: check for direct image attachment + animation request
    has_direct_attachment = has_image_attachment?(context)

    if has_direct_attachment and simple_animation_request?(text) do
      source_url = find_latest_image_url(context)

      {:ok,
       %{
         intent: :image_to_video,
         source_image_url: source_url,
         confidence: 0.95,
         method: :heuristic
       }}
    else
      classify_with_llm(text, context, params)
    end
  end

  # ============================================================================
  # LLM classification
  # ============================================================================

  defp classify_with_llm(text, context, params) do
    model = Config.classification_model()

    if is_nil(model) do
      Logger.debug("No classification model configured, defaulting to text_to_video")
      {:ok, default_result()}
    else
      call_llm(text, context, model, params)
    end
  end

  defp call_llm(text, context, model, params) do
    context_summary = build_context_summary(context)

    prompt =
      if context_summary != "" do
        "Recent conversation:\n#{context_summary}\n\nCurrent message: #{text}"
      else
        text
      end

    case LLMClient.llm_client().generate_object(
           model,
           prompt,
           @classification_schema,
           system_prompt: @classification_system_prompt
         ) do
      {:ok, response} ->
        maybe_record_usage(model, response.usage || %{}, params)
        parse_llm_response(response.object)

      {:error, reason} ->
        Logger.warning(
          "Video intent classification failed, defaulting to text_to_video: #{inspect(reason)}"
        )

        {:ok, default_result()}
    end
  end

  defp parse_llm_response(object) when is_map(object) do
    intent =
      case object["intent"] do
        "image_to_video" -> :image_to_video
        _ -> :text_to_video
      end

    {:ok,
     %{
       intent: intent,
       source_image_url: object["source_image_url"],
       confidence: parse_confidence(object["confidence"]),
       method: :llm
     }}
  end

  defp parse_llm_response(_), do: {:ok, default_result()}

  defp default_result do
    %{intent: :text_to_video, source_image_url: nil, confidence: 0.0, method: :heuristic}
  end

  # ============================================================================
  # Heuristic helpers
  # ============================================================================

  defp parse_confidence(c) when is_number(c), do: c |> max(0.0) |> min(1.0)
  defp parse_confidence(_), do: 0.5

  defp has_image_attachment?(context) do
    Enum.any?(context, fn msg ->
      (msg[:attachments] || msg["attachments"] || [])
      |> Enum.any?(fn
        att when is_map(att) ->
          type = att[:type] || att["type"] || ""
          String.starts_with?(to_string(type), "image")

        _non_map ->
          false
      end)
    end)
  end

  defp simple_animation_request?(text) do
    Regex.match?(
      ~r/(animate|bring to life|make.*(move|alive|video)|turn.*into.*video)/i,
      text || ""
    )
  end

  defp find_latest_image_url(context) do
    context
    |> Enum.flat_map(fn msg ->
      (msg[:attachments] || msg["attachments"] || [])
      |> Enum.filter(fn
        att when is_map(att) ->
          type = att[:type] || att["type"] || ""
          String.starts_with?(to_string(type), "image")

        _non_map ->
          false
      end)
    end)
    |> List.last()
    |> case do
      nil -> nil
      att -> att[:url] || att["url"]
    end
  end

  defp build_context_summary(context) do
    context
    |> Enum.take(-5)
    |> Enum.map(fn msg ->
      role = msg[:role] || msg["role"] || "user"
      text = msg[:text] || msg["text"] || ""
      attachments = msg[:attachments] || msg["attachments"] || []

      att_summary =
        attachments
        |> Enum.map(fn
          a when is_map(a) ->
            type = a[:type] || a["type"]
            url = a[:url] || a["url"]
            "[#{type}: #{url}]"

          id when is_binary(id) ->
            "[file: #{id}]"

          _ ->
            ""
        end)
        |> Enum.join(" ")

      "#{role}: #{text} #{att_summary}" |> String.trim()
    end)
    |> Enum.join("\n")
  end

  # ============================================================================
  # Usage recording
  # ============================================================================

  defp maybe_record_usage(model, usage, params) do
    if params[:user_id] do
      UsageRecorder.record!(
        user_id: params.user_id,
        conversation_id: params[:conversation_id],
        model_key: model,
        usage: usage,
        usage_type: :response,
        billable: false,
        action_name: "classify_video_intent"
      )
    end
  end
end
