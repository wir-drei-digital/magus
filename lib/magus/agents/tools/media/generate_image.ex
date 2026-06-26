defmodule Magus.Agents.Tools.Media.GenerateImage do
  @moduledoc """
  Tool wrapper for image generation. Defaults to Gemini 3.1 Flash Image;
  accepts an optional `model` key to route to other image-capable models.

  Checks subscription access and spend budget, validates the model has
  image output capability, then delegates to the GenerateImage action
  with validated options.
  """

  use Jido.Action,
    name: "generate_image",
    description: """
    Generate or edit an image using Gemini 3.1 Flash Image.

    Use this ONLY when the user explicitly asks you to create, draw, or generate an image,
    or to iterate on an existing image (e.g. "make it brighter", "remove the background",
    "turn it green").

    By default, the most recent image in the conversation is automatically passed as a
    reference so consecutive edits work. The user sees the current conversation images in
    your context, so when they say "the image" / "it" / "that", they mean the most recent one.

    - Editing / iterating (default): just write the change as the `prompt` (e.g. "remove the
      background", "turn it green, keep everything else"). The tool auto-attaches the last
      conversation image.
    - Starting fresh (unrelated image): set `auto_reference_last_image: false`.
    - Targeting a specific earlier image: pass its file_id in `reference_file_ids`. Explicit
      IDs take precedence over the auto-reference.

    Do not use this tool speculatively. Only call it when the user requests image work.

    You may pass `model` to choose a specific image model. Available image-capable
    models include: openrouter:openai/gpt-5-image (best at rendering text inside
    images), openrouter:black-forest-labs/flux.2-pro (best photoreal),
    openrouter:google/gemini-3-pro-image-preview (high-fidelity illustration), and
    openrouter:google/gemini-3.1-flash-image-preview (fast default). Omit `model`
    to use the fast default.
    """,
    schema: [
      prompt: [
        type: :string,
        required: true,
        doc: "Detailed text prompt describing the image to generate or the edit to apply"
      ],
      aspect_ratio: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Aspect ratio: 1:1, 2:3, 3:2, 3:4, 4:3, 4:5, 5:4, 9:16, 16:9, 21:9"
      ],
      quality: [
        type: {:or, [:string, nil]},
        default: nil,
        doc: "Image quality/size: 1K, 2K, 4K"
      ],
      reference_file_ids: [
        type: {:list, :string},
        default: [],
        doc:
          "Explicit file IDs to condition/edit on. Takes precedence over auto_reference_last_image. Use when targeting a specific earlier image rather than the most recent."
      ],
      auto_reference_last_image: [
        type: :boolean,
        default: true,
        doc:
          "Defaults to true: auto-attaches the most recent conversation image so consecutive edits work. Set to false when the user wants a brand-new, unrelated image."
      ],
      model: [
        type: {:or, [:string, nil]},
        default: nil,
        doc:
          "Optional model_key override. When omitted, uses Gemini 3.1 Flash Image. Must refer to an image-capable model (output_modalities includes \"image\"). Examples: openrouter:openai/gpt-5-image (best at text-in-image), openrouter:black-forest-labs/flux.2-pro (best photoreal), openrouter:google/gemini-3-pro-image-preview (high-fidelity illustration)."
      ]
    ]

  require Logger

  alias Magus.Agents.Signals
  alias Magus.Agents.Actions.GenerateImage, as: GenerateImageAction
  alias Magus.Agents.ImageGenerationConfig
  alias Magus.Agents.Tools.Media.Helpers, as: MediaHelpers

  import Magus.Agents.Tools.Helpers, only: [validate_context: 2, get_param: 2]

  def display_name, do: "Generating image..."

  def summarize_output(%{__attachments__: [_ | _] = ids}),
    do: "Generated #{length(ids)} image(s)"

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
      with {:ok, user} <- MediaHelpers.get_user(context),
           {:ok, model} <- MediaHelpers.fetch_model_by_key(resolve_model_key(params), user),
           :ok <- ensure_image_model(model),
           {:ok, :allowed} <- MediaHelpers.check_limits(user, :image_generation, model),
           {:ok, image_config} <- validate_image_config(params),
           {:ok, reference_ids} <- resolve_reference_ids(params, ctx) do
        Signals.emit_tool_progress(context, :generating, %{
          prompt: prompt,
          model: model.name,
          references: length(reference_ids)
        })

        messages = build_messages(prompt, reference_ids)

        action_params = %{
          model_key: model.key,
          model_id: model.id,
          model_name: model.name,
          messages: messages,
          user_id: ctx.user_id,
          conversation_id: ctx.conversation_id,
          image_config: image_config
        }

        case GenerateImageAction.run(action_params, %{}) do
          {:ok, result} ->
            file_ids = result.attachments || []
            files = MediaHelpers.load_file_refs(file_ids)

            {:ok,
             %{
               text: result.text || "",
               files: files,
               __attachments__: file_ids,
               hint:
                 "The generated image(s) will be attached to your next response message and rendered to the user automatically. In your reply, briefly describe what you created; do NOT embed the url yourself. To include an image in a brain page, call edit_brain with action: 'add_block', block_type: 'image', file_id: <id from files>. To include one in a draft, embed markdown ![alt](<url from files>) in the draft content."
             }}

          {:error, reason} ->
            Logger.error("GenerateImage tool failed", reason: inspect(reason))
            {:ok, %{error: "Image generation failed: #{MediaHelpers.format_error(reason)}"}}
        end
      else
        {:error, %Magus.Usage.PolicyError{} = err} ->
          {:ok, %{error: Magus.Usage.PolicyErrorMessage.message(err)}}

        {:error, reason} ->
          {:ok, %{error: "Image generation unavailable: #{MediaHelpers.format_error(reason)}"}}
      end
    end
  end

  # Resolve the list of reference file IDs. Explicit IDs win; otherwise, when
  # auto_reference_last_image is true, fall back to the most recent image in
  # the conversation (user upload or prior agent generation). On fallback,
  # returns {:error, msg} if the conversation has no images.
  defp resolve_reference_ids(params, ctx) do
    explicit =
      (get_param(params, :reference_file_ids) || [])
      |> Enum.filter(&is_binary/1)
      |> Enum.reject(&(&1 == ""))

    cond do
      explicit != [] ->
        case validate_file_ids(explicit, ctx) do
          {:ok, ids} ->
            {:ok, ids}

          {:error, missing} ->
            {:error,
             "reference_file_ids not found or not accessible: #{Enum.join(missing, ", ")}. " <>
               "If you don't know a specific id, omit reference_file_ids and rely on " <>
               "auto_reference_last_image (default true) which will pick the most recent " <>
               "image in this conversation."}
        end

      get_param(params, :auto_reference_last_image) == true ->
        # Silent fallback: if there's no prior image (fresh conversation), treat
        # the call as a brand-new generation rather than erroring. The user may
        # simply be making their first image request.
        case MediaHelpers.last_image_file_id(ctx.conversation_id) do
          nil -> {:ok, []}
          id -> {:ok, [id]}
        end

      true ->
        {:ok, []}
    end
  end

  # Check that each explicit reference_file_id exists and is owned by the
  # calling user. Returns {:ok, ids} if all resolve; {:error, missing_ids}
  # otherwise. We scope by user_id so a hallucinated or cross-user UUID cannot
  # slip through.
  defp validate_file_ids(ids, ctx) do
    require Ash.Query

    found =
      Magus.Files.File
      |> Ash.Query.filter(id in ^ids and user_id == ^ctx.user_id)
      |> Ash.Query.select([:id])
      |> Ash.read!(actor: %Magus.Agents.Support.AiAgent{})
      |> Enum.map(&to_string(&1.id))

    missing = Enum.reject(ids, &(&1 in found))

    if missing == [], do: {:ok, ids}, else: {:error, missing}
  end

  # Build the LLM context. Text-only when there are no reference images;
  # otherwise a single user message with image parts followed by the prompt.
  defp build_messages(prompt, []) do
    ReqLLM.Context.new([ReqLLM.Context.user(prompt)])
  end

  defp build_messages(prompt, reference_ids) when is_list(reference_ids) do
    image_parts =
      Magus.Files.load_llm_content_parts!(reference_ids,
        actor: %Magus.Agents.Support.AiAgent{}
      )
      |> Enum.flat_map(fn
        %{type: :image, media_type: mime, data: base64_data} ->
          [ReqLLM.Message.ContentPart.image(Base.decode64!(base64_data), mime)]

        _ ->
          []
      end)

    content_parts = image_parts ++ [ReqLLM.Message.ContentPart.text(prompt)]

    ReqLLM.Context.new([%ReqLLM.Message{role: :user, content: content_parts}])
  end

  defp validate_image_config(params) do
    aspect_ratio = get_param(params, :aspect_ratio)
    quality = get_param(params, :quality)
    allowed_ratios = ImageGenerationConfig.aspect_ratios()
    allowed_sizes = ImageGenerationConfig.image_sizes()

    errors =
      []
      |> maybe_invalid(aspect_ratio, allowed_ratios, "aspect_ratio")
      |> maybe_invalid(quality, allowed_sizes, "quality")

    case errors do
      [] ->
        config =
          ImageGenerationConfig.sanitize(%{
            "aspect_ratio" => aspect_ratio,
            "image_size" => quality
          })

        {:ok, if(map_size(config) == 0, do: nil, else: config)}

      _ ->
        {:error, Enum.join(errors, "; ")}
    end
  end

  defp resolve_model_key(params) do
    case get_param(params, :model) do
      nil -> Magus.Models.Roles.resolve(:image_default)
      "" -> Magus.Models.Roles.resolve(:image_default)
      key when is_binary(key) -> key
    end
  end

  defp ensure_image_model(%{output_modalities: modalities, key: key}) do
    if is_list(modalities) and "image" in modalities do
      :ok
    else
      {:error, "Model #{key} does not generate images. Pick an image-capable model."}
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
end
