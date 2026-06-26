defmodule Magus.Agents.Providers.AimlapiClient do
  @moduledoc """
  AIML API client for video generation models.

  Provides support for video generation via:
  - Google Veo 3.1 (text-to-video and image-to-video)
  - OpenAI Sora 2 (text-to-video and image-to-video)
  - Runway Gen4 Turbo (image-to-video)

  All video generation uses an async polling pattern:
  1. POST to create generation task, receive generation ID
  2. Poll GET endpoint with generation_id until status is "completed"
  3. Return video URL from completed response

  API Documentation: https://docs.aimlapi.com/api-references/video-models
  """

  require Logger

  @api_url "https://api.aimlapi.com/v2/video/generations"
  @poll_interval_ms 10_000
  @max_poll_attempts 60

  @type message :: %{role: String.t(), content: String.t() | list()}

  # Model types - determines if image input is required
  @text_to_video_models [
    "google/veo-3.1-t2v",
    "google/veo-3.1-t2v-fast",
    "openai/sora-2-pro-t2v",
    "bytedance/seedance-1-0-lite-t2v"
  ]

  @image_to_video_models [
    "google/veo-3.1-i2v",
    "google/veo-3.1-i2v-fast",
    "openai/sora-2-pro-i2v",
    "bytedance/seedance-1-0-lite-i2v"
  ]

  @doc """
  Generate a video using the specified model.

  ## Options
    - `:model` - Model ID (required)
    - `:prompt` - Text prompt describing the video (required for most models)
    - `:image_url` - URL of input image (required for image-to-video models)
    - `:aspect_ratio` - Video aspect ratio (default: "16:9")
    - `:duration` - Video duration in seconds (model-specific, typically 4, 5, 6, 8, or 10)
    - `:resolution` - Video resolution (default: "1080p" for Veo, "720p" for Sora)
    - `:generate_audio` - Generate audio track (Veo models only, default: true)
    - `:on_status` - Callback for status updates during polling

  ## Returns
    - `{:ok, result}` with video URL and metadata
    - `{:error, reason}` on failure
  """
  @spec generate_video(keyword()) :: {:ok, map()} | {:error, term()}
  def generate_video(opts) do
    model = Keyword.fetch!(opts, :model)
    prompt = Keyword.get(opts, :prompt)

    Logger.info("AimlapiClient.generate_video",
      model: model,
      prompt_length: prompt && String.length(prompt)
    )

    case get_api_key() do
      {:ok, api_key} ->
        body = build_request_body(opts)

        case create_generation(api_key, body) do
          {:ok, generation_id} ->
            on_status = Keyword.get(opts, :on_status)
            poll_for_completion(api_key, generation_id, on_status)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Generate a video using messages context (chat interface).

  Extracts the prompt from the latest user message and any image attachments
  for image-to-video models.

  ## Options
    Same as `generate_video/1`

  ## Returns
    - `{:ok, result}` matching the BaseClient result format
    - `{:error, reason}` on failure
  """
  @spec chat(list(message()), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, opts \\ []) do
    model = Keyword.get(opts, :model)
    {prompt, extracted_image_url} = extract_prompt_and_image(messages)

    # Use image_url from opts if provided (from metadata), otherwise try extracting from messages
    image_url = Keyword.get(opts, :image_url) || extracted_image_url

    # Determine if this is an image-to-video model
    is_i2v = model in @image_to_video_models

    Logger.debug("AimlapiClient.chat",
      model: model,
      is_i2v: is_i2v,
      has_image: not is_nil(image_url),
      image_from_opts: not is_nil(Keyword.get(opts, :image_url)),
      image_url_type:
        cond do
          is_nil(image_url) -> "none"
          String.starts_with?(image_url, "http") -> "url"
          String.starts_with?(image_url, "data:") -> "data_url"
          true -> "base64 (#{String.length(image_url)} chars)"
        end,
      message_count: length(messages),
      last_message_content_type: inspect_content_type(messages)
    )

    # Return error if image-to-video model but no image provided
    if is_i2v && is_nil(image_url) do
      Logger.warning(
        "AimlapiClient: Image-to-video model selected but no image found in messages or opts"
      )

      {:error,
       {:missing_image,
        "Image-to-video model #{model} requires an image input. Please provide an image attachment."}}
    else
      # Build generation options
      gen_opts =
        opts
        |> Keyword.put(:prompt, prompt)
        |> then(fn o ->
          if is_i2v && image_url do
            Keyword.put(o, :image_url, image_url)
          else
            o
          end
        end)

      case generate_video(gen_opts) do
        {:ok, result} ->
          # Convert to standard result format compatible with BaseClient
          {:ok,
           %{
             text: result[:text] || "",
             videos: result[:videos] || [],
             images: [],
             reasoning_details: [],
             tool_calls: [],
             finish_reason: "stop",
             usage: result[:usage]
           }}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Stream a chat completion (for video generation, this is non-streaming).

  Video generation doesn't support streaming, so this calls `chat/2` directly.
  The on_chunk callback is called once with the complete result.
  """
  @spec stream_chat(list(message()), keyword()) :: {:ok, map()} | {:error, term()}
  def stream_chat(messages, opts \\ []) do
    on_chunk = Keyword.get(opts, :on_chunk)

    case chat(messages, opts) do
      {:ok, result} ->
        if on_chunk && result.text != "", do: on_chunk.(result.text)
        {:ok, result}

      error ->
        error
    end
  end

  @doc """
  Check if a model is a text-to-video model.
  """
  def text_to_video_model?(model), do: model in @text_to_video_models

  @doc """
  Check if a model is an image-to-video model.
  """
  def image_to_video_model?(model), do: model in @image_to_video_models

  # Build the request body based on model type
  defp build_request_body(opts) do
    model = Keyword.fetch!(opts, :model)
    prompt = Keyword.get(opts, :prompt)

    base = %{model: model}

    base
    |> maybe_add(:prompt, prompt)
    |> maybe_add(:image_url, Keyword.get(opts, :image_url))
    |> maybe_add(:aspect_ratio, Keyword.get(opts, :aspect_ratio))
    |> maybe_add(:duration, Keyword.get(opts, :duration))
    |> maybe_add(:resolution, Keyword.get(opts, :resolution))
    |> maybe_add(:generate_audio, Keyword.get(opts, :generate_audio))
    |> maybe_add(:seed, Keyword.get(opts, :seed))
    |> maybe_add(:negative_prompt, Keyword.get(opts, :negative_prompt))
  end

  defp maybe_add(map, _key, nil), do: map
  defp maybe_add(map, key, value), do: Map.put(map, key, value)

  # Create a video generation task
  defp create_generation(api_key, body) do
    headers = build_headers(api_key)

    Logger.debug("AimlapiClient creating generation", body: inspect(body))

    case Req.post(@api_url, json: body, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: status, body: response_body}} when status in [200, 201] ->
        case response_body do
          %{"id" => generation_id} ->
            Logger.info("AimlapiClient generation created", generation_id: generation_id)
            {:ok, generation_id}

          _ ->
            Logger.error("AimlapiClient unexpected response", response: inspect(response_body))
            {:error, {:unexpected_response, response_body}}
        end

      {:ok, %{status: status, body: error_body}} ->
        Logger.error("AimlapiClient API error",
          status: status,
          error: inspect(error_body)
        )

        {:error, {:api_error, status, error_body}}

      {:error, error} ->
        Logger.error("AimlapiClient request failed", error: inspect(error))
        {:error, error}
    end
  end

  # Poll for generation completion
  defp poll_for_completion(api_key, generation_id, on_status, attempt \\ 1)

  defp poll_for_completion(_api_key, _generation_id, _on_status, attempt)
       when attempt > @max_poll_attempts do
    {:error, :timeout}
  end

  defp poll_for_completion(api_key, generation_id, on_status, attempt) do
    headers = build_headers(api_key)
    url = "#{@api_url}?generation_id=#{generation_id}"

    case Req.get(url, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: response_body}} ->
        handle_poll_response(api_key, generation_id, response_body, on_status, attempt)

      {:ok, %{status: status, body: error_body}} ->
        Logger.error("AimlapiClient poll error",
          status: status,
          error: inspect(error_body)
        )

        {:error, {:api_error, status, error_body}}

      {:error, error} ->
        Logger.error("AimlapiClient poll request failed", error: inspect(error))
        {:error, error}
    end
  end

  defp handle_poll_response(api_key, generation_id, response, on_status, attempt) do
    status = response["status"]

    Logger.info("AimlapiClient poll status",
      generation_id: generation_id,
      status: status,
      attempt: "#{attempt}/#{@max_poll_attempts}"
    )

    # Call status callback if provided
    if on_status, do: on_status.(status, attempt)

    case status do
      status when status in ["completed", "succeeded"] ->
        parse_completed_response(response)

      "failed" ->
        error_details = extract_error_message(response)
        Logger.error("AimlapiClient generation failed", error: error_details)
        {:error, {:generation_failed, error_details}}

      "error" ->
        error_details = extract_error_message(response)
        Logger.error("AimlapiClient generation failed", error: error_details)
        {:error, {:generation_failed, error_details}}

      status
      when status in ["queued", "generating", "processing", "pending", "waiting", "in_progress"] ->
        # Wait and poll again
        Process.sleep(@poll_interval_ms)
        poll_for_completion(api_key, generation_id, on_status, attempt + 1)

      unknown_status ->
        Logger.warning("AimlapiClient unknown status: #{inspect(unknown_status)}",
          generation_id: generation_id,
          response: inspect(response, limit: 500)
        )

        # Treat unknown statuses as errors — don't keep polling indefinitely
        {:error, {:unknown_status, unknown_status}}
    end
  end

  defp extract_error_message(response) do
    case response["error"] do
      %{"message" => msg} when is_binary(msg) -> msg
      msg when is_binary(msg) -> msg
      _ -> response["message"] || "Unknown error"
    end
  end

  # Parse the completed generation response
  defp parse_completed_response(response) do
    video = response["video"] || %{}
    meta = response["meta"] || %{}
    usage = meta["usage"] || %{}

    video_url = video["url"]
    duration = video["duration"]

    if video_url do
      Logger.info("AimlapiClient video generation complete",
        video_url: video_url,
        duration: duration
      )

      {:ok,
       %{
         text: "",
         videos: [
           %{
             "type" => "video",
             "url" => video_url,
             "duration" => duration
           }
         ],
         usage: %{
           credits_used: usage["credits_used"]
         }
       }}
    else
      Logger.error("AimlapiClient no video URL in response", response: inspect(response))
      {:error, :no_video_url}
    end
  end

  # Extract prompt and image URL from messages
  defp extract_prompt_and_image(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value({"Generate a video", nil}, fn msg ->
      role = Map.get(msg, :role) || Map.get(msg, "role")

      if role in [:user, "user"] do
        content = Map.get(msg, :content) || Map.get(msg, "content")
        {extract_text(content), extract_image_url(content)}
      end
    end)
  end

  defp extract_text(content) when is_binary(content), do: content

  defp extract_text(content) when is_list(content) do
    Enum.find_value(content, "Generate a video", fn
      %{type: :text, text: text} -> text
      %{type: "text", text: text} -> text
      %{"type" => "text", "text" => text} -> text
      _ -> nil
    end)
  end

  defp extract_text(_), do: "Generate a video"

  defp extract_image_url(content) when is_list(content) do
    result =
      Enum.find_value(content, fn
        # URL formats (external URLs)
        %{type: :image, url: url} when is_binary(url) ->
          {:url, url}

        %{type: "image", url: url} when is_binary(url) ->
          {:url, url}

        %{"type" => "image", "url" => url} when is_binary(url) ->
          {:url, url}

        %{type: :image_url, image_url: %{url: url}} when is_binary(url) ->
          {:url, url}

        %{"type" => "image_url", "image_url" => %{"url" => url}} when is_binary(url) ->
          {:url, url}

        # Binary data formats (from ContentPart structs) - encode to base64
        %{type: :image, media_type: _mime, data: data} when is_binary(data) ->
          {:binary, data}

        %{type: "image", media_type: _mime, data: data} when is_binary(data) ->
          {:binary, data}

        %{"type" => "image", "media_type" => _mime, "data" => data} when is_binary(data) ->
          {:binary, data}

        # OpenAI-style image_url with data URL - extract base64
        %{type: :image_url, image_url: %{url: "data:" <> _ = data_url}} ->
          {:data_url, data_url}

        %{"type" => "image_url", "image_url" => %{"url" => "data:" <> _ = data_url}} ->
          {:data_url, data_url}

        _ ->
          nil
      end)

    case result do
      {:url, url} ->
        # External URL - pass as-is
        url

      {:binary, data} ->
        # Raw binary data - encode to base64 for AIML API
        Base.encode64(data)

      {:data_url, data_url} ->
        # Extract base64 from data URL
        case Regex.run(~r/^data:[^;]+;base64,(.+)$/, data_url) do
          [_, base64] -> base64
          _ -> data_url
        end

      nil ->
        nil
    end
  end

  defp extract_image_url(_), do: nil

  # Debug helper to inspect message content types
  defp inspect_content_type([]), do: "empty"

  defp inspect_content_type(messages) do
    last_msg = List.last(messages)
    content = Map.get(last_msg, :content) || Map.get(last_msg, "content")

    cond do
      is_binary(content) ->
        "string"

      is_list(content) ->
        types =
          Enum.map(content, fn
            %{type: t} -> "#{t}"
            %{"type" => t} -> "#{t}"
            _ -> "unknown"
          end)

        "list[#{Enum.join(types, ", ")}]"

      true ->
        "other: #{inspect(content, limit: 100)}"
    end
  end

  # Build request headers
  defp build_headers(api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end

  # Get API key from environment
  defp get_api_key do
    case System.get_env("AIML_API_KEY") do
      nil ->
        Logger.error("AIML_API_KEY not set")
        {:error, :missing_api_key}

      key ->
        {:ok, key}
    end
  end
end
