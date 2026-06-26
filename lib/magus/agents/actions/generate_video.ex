defmodule Magus.Agents.Actions.GenerateVideo do
  @moduledoc """
  Jido Action for generating videos from text or image prompts.

  Routes to the appropriate provider based on the model key's provider prefix.
  OpenRouter is the primary provider for the active video roster; Fal.ai and
  AIML API are retained for legacy/deprecated rows. Each provider uses async
  polling:
  1. Submit generation request
  2. Poll until completion
  3. Download and create Files.File

  Creates Files.File records for generated videos and returns file IDs
  in the message attachments.
  """

  use Jido.Action,
    name: "generate_video",
    description: "Generate videos from text or image prompts using AI models",
    schema: [
      model_key: [type: :string, required: true, doc: "Model key in format 'provider:model_id'"],
      model_id: [type: {:or, [:string, nil]}, default: nil, doc: "Model ID for usage tracking"],
      model_name: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Model name for usage tracking"
      ],
      messages: [type: {:list, :map}, required: true, doc: "Conversation messages for context"],
      user_id: [type: :string, required: true, doc: "User ID for resource ownership"],
      conversation_id: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Conversation to associate resources with"
      ],
      input_image: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Input image URL/data URI for i2v models"
      ],
      attachments: [type: {:list, :string}, default: [], doc: "Resource IDs for input images"],
      video_config: [
        type: {:or, [:map, nil]},
        default: nil,
        doc: "Video generation config (aspect_ratio, duration, resolution, generate_audio)"
      ],
      emit_context: [
        type: {:or, [:map, nil]},
        default: nil,
        doc:
          "Event context map with :conversation_id, :parent_message_id, :correlation_id, :metadata"
      ]
    ]

  require Logger

  alias Magus.Agents.Persistence.UsageRecorder
  alias Magus.Agents.Routing.ModelKey
  alias Magus.Agents.VideoGenerationConfig
  alias Magus.Agents.Providers.AimlapiClient
  alias Magus.Agents.Providers.FalClient
  alias Magus.Agents.Providers.OpenRouterVideo
  alias Magus.Agents.Clients.VideoGen, as: VideoGenClient

  @impl true
  def run(params, _context) do
    model_key = params.model_key
    param_model_id = params[:model_id]
    model_name = params[:model_name]
    messages = params.messages
    user_id = params.user_id
    conversation_id = params[:conversation_id]
    emit_context = params[:emit_context]

    api_provider = ModelKey.extract_provider(model_key) || :aimlapi
    provider_model_id = ModelKey.extract_model_id(model_key)

    input_image = resolve_input_image(params)

    Logger.info("GenerateVideo.run #{inspect(provider_model_id)}")

    video_config = params[:video_config]

    case generate_for_provider(
           api_provider,
           provider_model_id,
           messages,
           input_image,
           video_config
         ) do
      {:ok, result} ->
        # Create Files.File records for videos/images
        file_ids = create_media_files(result, user_id, conversation_id)
        text = result[:text] || ""
        usage = result[:usage] || %{}
        new_message_id = Ash.UUIDv7.generate()

        # Record usage for video generation (include video_duration if available).
        # message_id is nil because the assistant's response hasn't been persisted
        # when tools run, and a fake UUID would violate message_usages' FK.
        if param_model_id && conversation_id do
          _ = model_name
          video_duration = result[:duration] || result[:video_duration]

          usage_with_duration =
            if video_duration, do: Map.put(usage, "video_duration", video_duration), else: usage

          UsageRecorder.record!(
            user_id: user_id,
            message_id: nil,
            conversation_id: conversation_id,
            model_key: model_key,
            usage: usage_with_duration,
            usage_type: :video_generation,
            action_name: "generate_video"
          )
        end

        # Note: Event emission removed - use Jido agent system for real-time updates
        _ = emit_context

        {:ok,
         %{
           message_id: new_message_id,
           text: text,
           attachments: file_ids,
           usage: usage
         }}

      {:error, reason} ->
        Logger.error("GenerateVideo failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  # Resolve input image from various sources
  defp resolve_input_image(params) do
    cond do
      params[:input_image] ->
        params[:input_image]

      image =
          Magus.Files.load_first_image_data_uri!(params[:attachments] || [],
            actor: %Magus.Agents.Support.AiAgent{}
          ) ->
        image

      true ->
        nil
    end
  end

  # Route to the appropriate provider
  defp generate_for_provider(:openrouter, model_id, messages, input_image, video_config) do
    opts =
      [model: model_id]
      |> maybe_put_image_url(input_image)
      |> Keyword.merge(VideoGenerationConfig.to_keyword_opts(video_config))

    openrouter_video_client().chat(ReqLLM.Context.to_list(messages), opts)
  end

  defp generate_for_provider(:aimlapi, model_id, messages, input_image, video_config) do
    opts =
      [model: model_id]
      |> maybe_add_image(input_image, model_id)
      |> Keyword.merge(VideoGenerationConfig.to_keyword_opts(video_config))

    VideoGenClient.video_gen_client().chat(ReqLLM.Context.to_list(messages), opts)
  end

  defp generate_for_provider(:fal, model_id, messages, input_image, video_config) do
    opts =
      [model: model_id]
      |> maybe_add_image(input_image, model_id)
      |> Keyword.merge(VideoGenerationConfig.to_keyword_opts(video_config))

    FalClient.chat(ReqLLM.Context.to_list(messages), opts)
  end

  defp generate_for_provider(provider, _model_id, _messages, _input_image, _video_config) do
    {:error, {:unsupported_provider, provider}}
  end

  defp maybe_add_image(opts, nil, _model_id), do: opts

  defp maybe_add_image(opts, input_image, model_id) do
    if AimlapiClient.image_to_video_model?(model_id) or FalClient.image_to_video_model?(model_id) do
      Keyword.put(opts, :image_url, input_image)
    else
      opts
    end
  end

  # OpenRouter video models do image-to-video on the same model id via
  # frame_images, so always pass the image when one is present (no model-id sniff).
  defp maybe_put_image_url(opts, nil), do: opts
  defp maybe_put_image_url(opts, image_url), do: Keyword.put(opts, :image_url, image_url)

  defp openrouter_video_client do
    Application.get_env(:magus, :openrouter_video_client, OpenRouterVideo)
  end

  # Create Files.File records for generated media
  defp create_media_files(result, user_id, conversation_id) do
    videos = result[:videos] || []
    images = result[:images] || []

    cond do
      videos != [] ->
        create_video_files(videos, user_id, conversation_id)

      images != [] ->
        create_image_files(images, user_id, conversation_id)

      true ->
        []
    end
  end

  defp create_video_files(videos, user_id, conversation_id) do
    videos
    |> Enum.with_index(1)
    |> Enum.map(fn {video, index} ->
      create_video_file(video, user_id, conversation_id, index)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp create_video_file(%{"url" => url}, user_id, conversation_id, index)
       when is_binary(url) do
    name = "generated_video_#{index}.mp4"

    # Args come first, then the input map for accepted attributes
    case Magus.Files.create_video_file_from_url(
           url,
           %{name: name, user_id: user_id, conversation_id: conversation_id},
           actor: %Magus.Agents.Support.AiAgent{}
         ) do
      {:ok, file} ->
        Logger.info("Created video file", file_id: file.id)
        file.id

      {:error, reason} ->
        Logger.error("Failed to create video file", reason: inspect(reason))
        nil
    end
  end

  # Handle binary content directly (useful for testing)
  defp create_video_file(
         %{"content" => content, "mime_type" => mime_type},
         user_id,
         conversation_id,
         index
       )
       when is_binary(content) do
    name = "generated_video_#{index}#{extension_for_video_mime(mime_type)}"

    case Magus.Files.create_video_file(
           content,
           mime_type,
           %{name: name, user_id: user_id, conversation_id: conversation_id},
           actor: %Magus.Agents.Support.AiAgent{}
         ) do
      {:ok, file} ->
        Logger.info("Created video file from content", file_id: file.id)
        file.id

      {:error, reason} ->
        Logger.error("Failed to create video file from content", reason: inspect(reason))
        nil
    end
  end

  defp create_video_file(video, _user_id, _conversation_id, _index) do
    Logger.warning("Unknown video format", video: inspect(video))
    nil
  end

  defp extension_for_video_mime("video/mp4"), do: ".mp4"
  defp extension_for_video_mime("video/webm"), do: ".webm"
  defp extension_for_video_mime(_), do: ".mp4"

  defp create_image_files(images, user_id, conversation_id) do
    images
    |> Enum.with_index(1)
    |> Enum.map(fn {image, index} ->
      create_image_file(image, user_id, conversation_id, index)
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp create_image_file(
         %{"base64" => base64, "mime_type" => mime_type},
         user_id,
         conversation_id,
         index
       ) do
    name = "generated_image_#{index}#{extension_for_mime(mime_type)}"

    case Base.decode64(base64) do
      {:ok, content} ->
        # Args come first, then the input map for accepted attributes
        case Magus.Files.create_image_file(
               content,
               mime_type,
               %{name: name, user_id: user_id, conversation_id: conversation_id},
               actor: %Magus.Agents.Support.AiAgent{}
             ) do
          {:ok, file} -> file.id
          {:error, _} -> nil
        end

      :error ->
        nil
    end
  end

  defp create_image_file(_, _user_id, _conversation_id, _index), do: nil

  defp extension_for_mime("image/png"), do: ".png"
  defp extension_for_mime("image/jpeg"), do: ".jpg"
  defp extension_for_mime("image/webp"), do: ".webp"
  defp extension_for_mime(_), do: ".png"
end
