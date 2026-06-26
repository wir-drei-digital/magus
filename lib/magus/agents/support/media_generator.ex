defmodule Magus.Agents.Support.MediaGenerator do
  @moduledoc """
  Handles image and video generation for the LLM strategy.

  Responsible for:
  - Generating images via GenerateImage action
  - Generating videos via GenerateVideo action
  - Error handling for generation failures
  """

  require Logger

  alias Magus.Agents.Signals
  alias Magus.Agents.Actions.GenerateImage
  alias Magus.Agents.Actions.GenerateVideo

  alias Magus.Agents.Context.ConversationState, as: State
  alias Magus.Agents.Persistence.MessagePersistence

  @doc """
  Generates an image from the user's prompt.
  Returns `{:ok, agent, state}` or `{:error, agent, state}`.
  """
  def generate_image(agent, %State{} = state) do
    Logger.info("Generating image for conversation #{state.conversation_id}")

    # Broadcast that we're generating an image
    Signals.state_change(state.conversation_id, :generating_image)

    # Build params for GenerateImage action
    params = %{
      model_key: state.model_record.key,
      model_id: state.model_record.id,
      model_name: state.model_record.name,
      messages: state.llm_context,
      user_id: state.user_id,
      conversation_id: state.conversation_id,
      image_config: state.conversation && state.conversation.image_generation_settings
    }

    case GenerateImage.run(params, %{}) do
      {:ok, result} ->
        # Update state with results
        new_state = %State{
          state
          | accumulated_text: result.text || "",
            current_message_id: result.message_id
        }

        # Emit completion event
        Signals.text_complete(
          state.conversation_id,
          result.message_id,
          result.text || "",
          result.usage || %{}
        )

        # Persist the response with attachments
        MessagePersistence.persist_media_response(new_state, result.attachments || [])

        {:ok, agent, new_state}

      {:error, error} ->
        Logger.error("Image generation failed: #{inspect(error)}")
        {:error, agent, state, error}
    end
  end

  @doc """
  Generates a video from the user's prompt (optionally with an image attachment).
  Returns `{:ok, agent, state}` or `{:error, agent, state}`.
  """
  def generate_video(agent, %State{} = state) do
    Logger.info("Generating video for conversation #{state.conversation_id}")

    # Broadcast that we're generating a video
    Signals.state_change(state.conversation_id, :generating_video)

    # Extract the most recent image: first try llm context, then scan conversation messages
    input_image =
      extract_image_from_context(state.llm_context) ||
        load_image_from_conversation(state.conversation_id)

    # Build params for GenerateVideo action
    params = %{
      model_key: state.model_record.key,
      model_id: state.model_record.id,
      model_name: state.model_record.name,
      messages: state.llm_context,
      user_id: state.user_id,
      conversation_id: state.conversation_id,
      input_image: input_image,
      video_config: state.conversation && state.conversation.video_generation_settings
    }

    case GenerateVideo.run(params, %{}) do
      {:ok, result} ->
        # Update state with results
        new_state = %State{
          state
          | accumulated_text: result.text || "",
            current_message_id: result.message_id
        }

        # Emit completion event
        Signals.text_complete(
          state.conversation_id,
          result.message_id,
          result.text || "",
          result.usage || %{}
        )

        # Persist the response with attachments
        MessagePersistence.persist_media_response(new_state, result.attachments || [])

        {:ok, agent, new_state}

      {:error, error} ->
        Logger.error("Video generation failed: #{inspect(error)}")
        {:error, agent, state, error}
    end
  end

  @doc """
  Creates an error event message and broadcasts error signal for media generation failure.

  Does NOT modify agent state or broadcast idle — the caller handles
  finalization via `finalize_response/3`.
  """
  def broadcast_error_event(%State{} = state, error, media_type) do
    error_text =
      case error do
        {:unsupported_provider, provider} ->
          "#{media_type} generation is not supported for provider: #{provider}"

        %{message: msg} when is_binary(msg) ->
          msg

        _ ->
          "Failed to generate #{media_type}"
      end

    Logger.error("Generation error for conversation #{state.conversation_id}: #{error_text}")

    # Create error event message
    Magus.Chat.create_event_message!(error_text, state.conversation_id, authorize?: false)

    # Broadcast error to UI so it can update thinking status
    Signals.error(
      state.conversation_id,
      state.parent_message_id || "unknown",
      "generation_error",
      error_text
    )
  end

  # Extracts the most recent image from the llm context as a base64 data URI.
  # Scans messages in reverse to find the last image ContentPart.
  defp extract_image_from_context(nil), do: nil

  defp extract_image_from_context(%ReqLLM.Context{} = context) do
    context
    |> ReqLLM.Context.to_list()
    |> Enum.reverse()
    |> Enum.find_value(fn msg ->
      msg.content
      |> Enum.reverse()
      |> Enum.find_value(fn
        %{type: :image, data: data, media_type: media_type} when is_binary(data) ->
          "data:#{media_type};base64,#{Base.encode64(data)}"

        _ ->
          nil
      end)
    end)
  end

  defp extract_image_from_context(_), do: nil

  # Fallback: scan conversation messages for the most recent image attachment
  # and load it as a data URI directly from the Files module.
  defp load_image_from_conversation(conversation_id) do
    require Ash.Query

    case Magus.Chat.Message
         |> Ash.Query.filter(conversation_id == ^conversation_id and attachments != [])
         |> Ash.Query.sort(inserted_at: :desc)
         |> Ash.Query.limit(10)
         |> Ash.read(authorize?: false) do
      {:ok, messages} ->
        Enum.find_value(messages, fn msg ->
          case Magus.Files.load_first_image_data_uri(msg.attachments,
                 actor: %Magus.Agents.Support.AiAgent{}
               ) do
            {:ok, data_uri} when is_binary(data_uri) -> data_uri
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end
end
