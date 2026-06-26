defmodule Magus.Agents.Tools.Media.GenerateVideo do
  @moduledoc """
  Tool wrapper for video generation.

  Defaults to OpenRouter Veo 3.1 Fast and accepts a `model` override across the
  available OpenRouter video models (higher-fidelity Veo, Sora, Seedance, etc.).

  Supports two modes:
  - `text_to_video` (default): generates video from a text prompt
  - `image_to_video`: animates an image from the conversation into a video

  Checks subscription access and spend budget, then delegates to the
  GenerateVideo action with the resolved model and validated options.
  """

  use Jido.Action,
    name: "generate_video",
    description: """
    Generate a video using Veo 3.1 Fast. Two modes are available:

    - "text_to_video" (default): generate a video from a text prompt
    - "image_to_video": animate a recent image from the conversation into a video

    Use this ONLY when the user explicitly asks to create or generate a video.
    Do not use this tool speculatively. Video generation takes 1-3 minutes.

    You may pass `model` to choose a specific video model. Available video
    models include: openrouter:google/veo-3.1-fast (fast default),
    openrouter:google/veo-3.1 (higher fidelity), openrouter:openai/sora-2-pro
    (text-to-video only), and openrouter:bytedance/seedance-2.0 (cheapest).
    Omit `model` to use the fast default.
    """,
    schema: [
      prompt: [
        type: :string,
        required: true,
        doc: "Text prompt describing the video to generate (or the motion for image_to_video)"
      ],
      mode: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Generation mode: \"text_to_video\" (default) or \"image_to_video\""
      ],
      aspect_ratio: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Aspect ratio: 16:9, 9:16 (text_to_video) or auto, 16:9, 9:16 (image_to_video)"
      ],
      duration: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Duration in seconds: 4, 6, 8"
      ],
      resolution: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Resolution: 720p, 1080p, 4k"
      ],
      generate_audio: [
        type: {:or, [:boolean, nil]},
        default: nil,
        doc: "Generate synchronized audio (default: false)"
      ],
      model: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "Optional model_key override. When omitted, uses Veo 3.1 Fast. Must be a video-capable model. Examples: openrouter:google/veo-3.1 (higher fidelity), openrouter:openai/sora-2-pro (text-to-video only), openrouter:bytedance/seedance-2.0 (cheapest)."
      ]
    ]

  require Logger

  @doc false
  def default_model_key, do: Magus.Models.Roles.resolve(:video_t2v)

  @t2v_aspect_ratios ~w(16:9 9:16)
  @i2v_aspect_ratios ~w(auto 16:9 9:16)
  @durations ~w(4 6 8)
  @resolutions ~w(720p 1080p 4k)

  alias Magus.Agents.Signals
  alias Magus.Agents.Actions.GenerateVideo, as: GenerateVideoAction
  alias Magus.Agents.Tools.Media.Helpers, as: MediaHelpers

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2]

  def display_name, do: "Generating video..."

  def summarize_output(%{__attachments__: [_ | _] = ids}),
    do: "Generated #{length(ids)} video(s)"

  def summarize_output(%{error: e}), do: "Error: #{e}"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    case validate_context(context, [:user_id, :conversation_id]) do
      {:ok, ctx} -> generate(params, ctx, context)
      {:error, message} -> {:ok, %{error: message}}
    end
  end

  defp generate(params, ctx, context) do
    prompt = get_param(params, :prompt) || ""

    if String.trim(prompt) == "" do
      {:ok, %{error: "Prompt cannot be empty"}}
    else
      i2v? = get_param(params, :mode) == "image_to_video"
      model_key = resolve_model_key(params, i2v?)

      with {:ok, user} <- MediaHelpers.get_user(context),
           :ok <- validate_mode(get_param(params, :mode)),
           {:ok, model} <- MediaHelpers.fetch_model_by_key(model_key, user),
           :ok <- ensure_video_model(model),
           {:ok, :allowed} <- MediaHelpers.check_limits(user, :video_generation, model),
           {:ok, input_image} <- resolve_input_image(i2v?, ctx.conversation_id, user),
           {:ok, video_config} <- validate_video_config(params, i2v?) do
        Signals.emit_tool_progress(context, :generating, %{
          prompt: prompt,
          model: model.name,
          mode: if(i2v?, do: "image_to_video", else: "text_to_video")
        })

        messages = ReqLLM.Context.new([ReqLLM.Context.user(prompt)])

        action_params = %{
          model_key: model.key,
          model_id: model.id,
          model_name: model.name,
          messages: messages,
          user_id: ctx.user_id,
          conversation_id: ctx.conversation_id,
          input_image: input_image,
          video_config: video_config
        }

        case GenerateVideoAction.run(action_params, %{}) do
          {:ok, result} ->
            file_ids = result.attachments || []
            files = MediaHelpers.load_file_refs(file_ids)

            {:ok,
             %{
               text: result.text || "",
               files: files,
               __attachments__: file_ids,
               hint:
                 "The generated video(s) will be attached to your next response message and rendered to the user automatically. In your reply, briefly describe what you created; do NOT embed the url yourself. To include a video in a brain page, call edit_brain with action: 'add_block', block_type: 'file', file_id: <id from files>. To reference one in a draft, embed the url from files as a markdown link."
             }}

          {:error, reason} ->
            Logger.error("GenerateVideo tool failed", reason: inspect(reason))
            {:ok, %{error: "Video generation failed: #{MediaHelpers.format_error(reason)}"}}
        end
      else
        {:error, %Magus.Usage.PolicyError{} = err} ->
          {:ok, %{error: Magus.Usage.PolicyErrorMessage.message(err)}}

        {:error, reason} ->
          {:ok, %{error: "Video generation unavailable: #{MediaHelpers.format_error(reason)}"}}
      end
    end
  end

  defp resolve_input_image(false, _conversation_id, _actor), do: {:ok, nil}

  defp resolve_input_image(true, conversation_id, actor) do
    case MediaHelpers.load_image_from_conversation(conversation_id, actor) do
      nil -> {:error, "No image found in conversation. Upload an image first."}
      image -> {:ok, image}
    end
  end

  @valid_modes [nil, "text_to_video", "image_to_video"]

  defp validate_mode(mode) when mode in @valid_modes, do: :ok

  defp validate_mode(mode) do
    {:error, "Invalid mode #{inspect(mode)}, must be one of: text_to_video, image_to_video"}
  end

  defp validate_video_config(params, i2v?) do
    allowed_ratios = if i2v?, do: @i2v_aspect_ratios, else: @t2v_aspect_ratios

    duration = get_param(params, :duration)
    duration = if is_integer(duration), do: to_string(duration), else: duration

    aspect_ratio = get_param(params, :aspect_ratio)
    resolution = get_param(params, :resolution)
    generate_audio = get_param(params, :generate_audio)

    errors =
      []
      |> maybe_invalid(aspect_ratio, allowed_ratios, "aspect_ratio")
      |> maybe_invalid(duration, @durations, "duration")
      |> maybe_invalid(resolution, @resolutions, "resolution")
      |> maybe_invalid_audio(generate_audio)

    case errors do
      [] ->
        config =
          %{}
          |> put_if(aspect_ratio, "aspect_ratio")
          |> put_if(duration, "duration")
          |> put_if(resolution, "resolution")
          |> put_audio(generate_audio)

        {:ok, if(map_size(config) == 0, do: nil, else: config)}

      _ ->
        {:error, Enum.join(errors, "; ")}
    end
  end

  defp maybe_invalid(errors, nil, _allowed, _name), do: errors

  defp maybe_invalid(errors, value, allowed, name) do
    if value in allowed,
      do: errors,
      else:
        errors ++
          ["Invalid #{name} #{inspect(value)}, must be one of: #{Enum.join(allowed, ", ")}"]
  end

  defp maybe_invalid_audio(errors, nil), do: errors
  defp maybe_invalid_audio(errors, val) when is_boolean(val), do: errors
  defp maybe_invalid_audio(errors, "true"), do: errors
  defp maybe_invalid_audio(errors, "false"), do: errors

  defp maybe_invalid_audio(errors, val) do
    errors ++ ["Invalid generate_audio #{inspect(val)}, must be true or false"]
  end

  defp put_if(map, nil, _key), do: map
  defp put_if(map, value, key), do: Map.put(map, key, value)

  defp put_audio(map, nil), do: map
  defp put_audio(map, val) when is_boolean(val), do: Map.put(map, "generate_audio", val)
  defp put_audio(map, "true"), do: Map.put(map, "generate_audio", true)
  defp put_audio(map, "false"), do: Map.put(map, "generate_audio", false)
  defp put_audio(map, _), do: map

  defp resolve_model_key(params, i2v?) do
    case get_param(params, :model) do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        if i2v?,
          do: Magus.Models.Roles.resolve(:video_i2v),
          else: Magus.Models.Roles.resolve(:video_t2v)
    end
  end

  defp ensure_video_model(%{output_modalities: modalities, key: key}) do
    if is_list(modalities) and "video" in modalities do
      :ok
    else
      {:error, "Model #{key} does not generate videos. Pick a video-capable model."}
    end
  end
end
