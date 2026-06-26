defmodule Magus.Agents.Routing.AutoRouteResolver do
  @moduledoc """
  Reactor step that resolves `:auto` model keys to concrete model keys.

  For each model type in the incoming `model_keys` map:

  - **chat**: If `:auto`, classifies the message and picks the best
    routing-eligible model via `AutoRouter`. Falls back to system default
    if no route matches. If already a string, passes through unchanged.
  - **image**: If `:auto`, looks up the `:image` routing slot via
    `ModelMatcher.find_media_model/1`. Falls back to system default if no
    slot is configured. If already a string, passes through unchanged.
  - **video**: If `:auto`, uses `ClassifyVideoIntent` to determine whether
    the request is text-to-video or image-to-video, then looks up the
    corresponding routing slot (`:text_to_video` or `:image_to_video`) via
    `ModelMatcher.find_media_model/1`. For image-to-video with no slot,
    falls back to any video model that accepts image input modality, then
    to system default. If already a string, passes through unchanged.

  ## Returns

      {:ok, %{
        model_keys: %{chat: "resolved-key", image: "resolved-key", video: "resolved-key"},
        routing_reason: "Routed to X for coding task" | nil
      }}
  """

  require Logger

  alias Magus.Agents.Actions.ClassifyVideoIntent
  alias Magus.Agents.Routing.AutoRouter
  alias Magus.Agents.Routing.ModelKeyResolver
  alias Magus.Agents.Routing.ModelMatcher
  alias Magus.Usage.Calculator

  @doc """
  Resolve `:auto` model keys to concrete model keys.

  Accepts `model_keys`, a message map, and an optional conversation struct.
  Returns `{:ok, %{model_keys: ..., routing_reason: ...}}`.
  """
  def resolve(model_keys, message, conversation \\ nil, opts \\ []) do
    run(
      %{
        model_keys: model_keys,
        message: message,
        conversation: conversation,
        recent_messages: Keyword.get(opts, :recent_messages, [])
      },
      nil,
      nil
    )
  end

  defp run(arguments, _context, _options) do
    %{model_keys: model_keys, message: message} = arguments
    conversation = Map.get(arguments, :conversation)

    # Resolve chat model
    {chat_key, routing_reason} =
      case model_keys.chat do
        :auto ->
          constraints = get_routing_constraints(conversation)

          case resolve_auto_chat(model_keys, message, conversation, constraints) do
            {:ok, result} -> {result.model_keys.chat, result.routing_reason}
          end

        explicit ->
          {explicit, nil}
      end

    # Resolve image model (routing slot when :auto, fallback to system default)
    image_key =
      case model_keys.image do
        :auto ->
          case ModelMatcher.find_media_model(:image) do
            {:ok, key} -> key
            :no_match -> ModelKeyResolver.default_model_key(:image)
          end

        explicit ->
          explicit
      end

    # Resolve video model (uses ClassifyVideoIntent for :auto)
    video_key =
      case model_keys.video do
        :auto -> resolve_auto_video(message, Map.get(arguments, :recent_messages, []))
        explicit -> explicit
      end

    {:ok,
     %{
       model_keys: %{chat: chat_key, image: image_key, video: video_key},
       routing_reason: routing_reason
     }}
  end

  defp resolve_auto_chat(model_keys, message, conversation, constraints) do
    text = message.text || ""
    mode = message.mode
    metadata = message.metadata || %{}
    required_modalities = Map.get(metadata, "required_input_modalities", [])
    max_tier = constraints.max_tier

    route_opts = [
      mode: mode,
      metadata: metadata,
      max_tier: max_tier,
      required_modalities: required_modalities,
      user_id: conversation && conversation.user_id,
      conversation_id: conversation && Map.get(conversation, :id)
    ]

    case AutoRouter.route(text, route_opts) do
      {:ok, model_key, classification} ->
        Logger.info(
          "AutoRouter: #{classification.intent}/#{classification.complexity} → #{model_key}"
        )

        resolved_keys = %{model_keys | chat: model_key}
        reason = build_routing_reason(model_key, classification, constraints)
        {:ok, %{model_keys: resolved_keys, routing_reason: reason}}

      :no_route ->
        fallback = default_chat_key()

        Logger.info(
          "AutoRouteResolver: no route found, falling back to system default=#{fallback}"
        )

        {:ok, %{model_keys: %{model_keys | chat: fallback}, routing_reason: nil}}
    end
  end

  @default_constraints %{max_tier: nil}

  defp get_routing_constraints(nil), do: @default_constraints

  defp get_routing_constraints(conversation) do
    user_id = conversation.user_id

    case Magus.Usage.get_user_subscription(user_id,
           load: [:usage_plan],
           authorize?: false
         ) do
      {:ok, sub} ->
        limits = Calculator.get_effective_limits_from_subscription(sub)

        if limits[:exempt] == true do
          @default_constraints
        else
          plan_tier = sub.usage_plan.max_routing_tier || :simple

          %{max_tier: plan_tier}
        end

      {:error, _} ->
        %{max_tier: :simple}
    end
  end

  defp build_routing_reason(model_key, classification, constraints) do
    model_name =
      model_key
      |> String.split("/")
      |> List.last()

    intent_label =
      case classification.intent do
        :coding -> "coding"
        :search -> "web search"
        :reasoning -> "reasoning"
        :creative -> "creative writing"
        :chat -> "conversation"
      end

    base = "Auto-routed to #{model_name} for #{intent_label}"

    qualifiers =
      [
        if(constraints.max_tier, do: "tier capped to #{constraints.max_tier}")
      ]
      |> Enum.reject(&is_nil/1)

    case qualifiers do
      [] -> base
      parts -> "#{base} (#{Enum.join(parts, ", ")})"
    end
  end

  defp default_chat_key do
    ModelKeyResolver.default_model_key(:chat)
  end

  defp resolve_auto_video(message, recent_messages) do
    text = message.text || ""

    video_specialty =
      case ClassifyVideoIntent.run(%{text: text, conversation_context: recent_messages}, %{}) do
        {:ok, %{intent: :image_to_video}} -> :image_to_video
        _ -> :text_to_video
      end

    case ModelMatcher.find_media_model(video_specialty) do
      {:ok, key} ->
        key

      :no_match ->
        if video_specialty == :image_to_video do
          case pick_image_capable_video_model() do
            {:ok, key} -> key
            :no_match -> ModelKeyResolver.default_model_key(:video)
          end
        else
          ModelKeyResolver.default_model_key(:video)
        end
    end
  end

  defp pick_image_capable_video_model do
    case Magus.Chat.list_video_generation_models(authorize?: false) do
      {:ok, models} ->
        case Enum.find(models, fn m -> "image" in (m.input_modalities || []) end) do
          nil -> :no_match
          model -> {:ok, model.key}
        end

      _ ->
        :no_match
    end
  end
end
