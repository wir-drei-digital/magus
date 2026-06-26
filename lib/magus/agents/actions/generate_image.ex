defmodule Magus.Agents.Actions.GenerateImage do
  @moduledoc """
  Jido Action for generating images from text prompts using ReqLLM.Images.

  Creates Files.File records for generated images and returns file IDs
  in the message attachments.
  """

  use Jido.Action,
    name: "generate_image",
    description: "Generate images from text prompts using AI models",
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
      emit_context: [
        type: {:or, [:map, nil]},
        default: nil,
        doc:
          "Event context map with :conversation_id, :parent_message_id, :correlation_id, :metadata"
      ],
      image_config: [
        type: {:or, [:map, nil]},
        default: nil,
        doc: "OpenRouter image_config (aspect_ratio, image_size)"
      ]
    ]

  require Logger

  alias Magus.Agents.Clients.ImageGen, as: ImageGenClient
  alias Magus.Agents.Persistence.UsageRecorder

  @impl true
  def run(params, _context) do
    model_key = params.model_key
    model_id = params[:model_id]
    model_name = params[:model_name]
    messages = params.messages
    user_id = params.user_id
    conversation_id = params[:conversation_id]
    emit_context = params[:emit_context]

    context = ReqLLM.Context.to_list(messages)

    Logger.info("GenerateImage.run",
      model_key: model_key,
      message_count: length(context)
    )

    case ImageGenClient.image_gen_client().generate_image(model_key, context,
           image_config: params[:image_config]
         ) do
      {:ok, response} ->
        # Extract and store images as Files.File records
        file_ids = create_image_files(response, user_id, conversation_id)

        # Get text from response (response is %{text: ..., images: ...})
        text = response.text || ""
        usage = response.usage || %{}
        new_message_id = Ash.UUIDv7.generate()

        # Record usage for image generation. We use message_id: nil because the
        # assistant's response message hasn't been persisted yet when a tool
        # runs, and any fabricated UUID would violate the FK on message_usages.
        if model_id && conversation_id do
          _ = model_name

          UsageRecorder.record!(
            user_id: user_id,
            message_id: nil,
            conversation_id: conversation_id,
            model_key: model_key,
            usage: usage,
            usage_type: :image_generation,
            action_name: "generate_image"
          )
        end

        # Note: Event emission removed - use Jido agent system for real-time updates
        _ = emit_context

        {:ok,
         %{
           message_id: new_message_id,
           text: text,
           attachments: file_ids,
           usage: usage,
           reasoning_summary: []
         }}

      {:error, reason} ->
        Logger.error("GenerateImage failed", reason: inspect(reason))
        {:error, reason}
    end
  end

  # Create Files.File records for each generated image
  # response is %{text: ..., images: [...], usage: ...}
  defp create_image_files(response, user_id, conversation_id) do
    (response.images || [])
    |> Enum.with_index(1)
    |> Enum.map(fn {image, index} ->
      create_file_from_image(image, user_id, conversation_id, index)
    end)
    |> Enum.reject(&is_nil/1)
  end

  # Handle ReqLLM.Message.ContentPart structs
  defp create_file_from_image(
         %ReqLLM.Message.ContentPart{type: :image, data: data, media_type: media_type},
         user_id,
         conversation_id,
         index
       )
       when is_binary(data) do
    mime_type = media_type || "image/png"
    create_image_from_binary(data, mime_type, user_id, conversation_id, index)
  end

  # Handle map format from OpenRouter (data_url format)
  defp create_file_from_image(
         %{"type" => "image", "data_url" => data_url},
         user_id,
         conversation_id,
         index
       )
       when is_binary(data_url) do
    case parse_data_url(data_url) do
      {:ok, mime_type, data} ->
        create_image_from_binary(data, mime_type, user_id, conversation_id, index)

      :error ->
        Logger.warning("Failed to parse data URL", data_url: String.slice(data_url, 0, 50))
        nil
    end
  end

  defp create_file_from_image(content_part, _user_id, _conversation_id, _index) do
    Logger.warning("Unknown image format", content_part: inspect(content_part))
    nil
  end

  defp create_image_from_binary(data, mime_type, user_id, conversation_id, index) do
    name = "generated_image_#{index}#{extension_for_mime(mime_type)}"

    # Args come first, then the input map for accepted attributes
    case Magus.Files.create_image_file(
           data,
           mime_type,
           %{name: name, user_id: user_id, conversation_id: conversation_id},
           actor: %Magus.Agents.Support.AiAgent{}
         ) do
      {:ok, file} ->
        Logger.info("Created image file", file_id: file.id)
        file.id

      {:error, reason} ->
        Logger.error("Failed to create image file", reason: inspect(reason))
        nil
    end
  end

  defp parse_data_url("data:" <> rest) do
    case String.split(rest, ";base64,", parts: 2) do
      [mime_type, base64_data] ->
        case Base.decode64(base64_data) do
          {:ok, data} -> {:ok, mime_type, data}
          :error -> :error
        end

      _ ->
        :error
    end
  end

  defp parse_data_url(_), do: :error

  defp extension_for_mime("image/png"), do: ".png"
  defp extension_for_mime("image/jpeg"), do: ".jpg"
  defp extension_for_mime("image/webp"), do: ".webp"
  defp extension_for_mime("image/gif"), do: ".gif"
  defp extension_for_mime(_), do: ".png"
end
