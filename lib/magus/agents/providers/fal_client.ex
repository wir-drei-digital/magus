defmodule Magus.Agents.Providers.FalClient do
  @moduledoc """
  Fal.ai client for video generation models using the queue-based API.

  Provides support for video generation via:
  - Google Veo 3.1 (text-to-video and image-to-video)
  - OpenAI Sora 2 (text-to-video and image-to-video)
  - ByteDance Seedance (text-to-video and image-to-video)

  All video generation uses Fal's async queue pattern:
  1. POST to queue endpoint, receive request_id
  2. Poll status endpoint until COMPLETED
  3. Fetch result from result endpoint
  4. Return video URL

  API Documentation: https://fal.ai/docs/model-endpoints/queue
  """

  require Logger

  @queue_base_url "https://queue.fal.run"
  @poll_interval_ms 10_000
  @max_poll_attempts 360

  @type message :: %{role: String.t(), content: String.t() | list()}

  @doc """
  Generate a video using messages context (chat interface).

  Extracts the prompt from the latest user message and any image attachments
  for image-to-video models.

  ## Options
    - `:model` - Model ID (required)
    - `:aspect_ratio` - Video aspect ratio (e.g. "16:9")
    - `:duration` - Video duration in seconds
    - `:resolution` - Video resolution (e.g. "720p", "1080p")
    - `:generate_audio` - Generate audio track (Veo models only)
    - `:on_status` - Callback for status updates during polling

  ## Returns
    - `{:ok, result}` matching the standard result format
    - `{:error, reason}` on failure
  """
  @spec chat(list(message()), keyword()) :: {:ok, map()} | {:error, term()}
  def chat(messages, opts \\ []) do
    model = Keyword.get(opts, :model)
    {prompt, extracted_image_url} = extract_prompt_and_image(messages)

    # Use image_url from opts if provided (from metadata), otherwise extract from messages
    image_url = Keyword.get(opts, :image_url) || extracted_image_url

    is_i2v = image_to_video_model?(model)

    Logger.debug("FalClient.chat",
      model: model,
      is_i2v: is_i2v,
      has_image: not is_nil(image_url),
      message_count: length(messages)
    )

    if is_i2v && is_nil(image_url) do
      Logger.warning(
        "FalClient: Image-to-video model selected but no image found in messages or opts"
      )

      {:error,
       {:missing_image,
        "Image-to-video model #{model} requires an image input. Please provide an image attachment."}}
    else
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

      on_status = Keyword.get(opts, :on_status)

      case generate_video(model, gen_opts, on_status) do
        {:ok, result} ->
          {:ok,
           %{
             text: result[:text] || "",
             videos: result[:videos] || [],
             images: [],
             reasoning_details: [],
             tool_calls: [],
             finish_reason: "stop",
             usage: result[:usage] || %{}
           }}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  @doc """
  Check if a model is an image-to-video model (model_id contains "image-to-video").
  """
  @spec image_to_video_model?(String.t() | nil) :: boolean()
  def image_to_video_model?(nil), do: false
  def image_to_video_model?(model_id), do: String.contains?(model_id, "image-to-video")

  @doc """
  Build the request body for the given model family and options.

  Handles per-family differences in duration encoding and audio support.
  Public for testability.
  """
  @spec build_request_body(String.t(), map()) :: map()
  def build_request_body(model_id, opts) do
    %{"prompt" => opts[:prompt]}
    |> maybe_put_string("image_url", opts[:image_url])
    |> maybe_put_string("aspect_ratio", opts[:aspect_ratio])
    |> put_duration(model_id, opts[:duration])
    |> maybe_put_string("resolution", opts[:resolution])
    |> maybe_put_generate_audio(model_id, opts[:generate_audio])
  end

  # ---------------------------------------------------------------------------
  # Private: Video generation pipeline
  # ---------------------------------------------------------------------------

  defp generate_video(model_id, opts, on_status) do
    Logger.info("FalClient.generate_video",
      model: model_id,
      prompt_length: opts[:prompt] && String.length(opts[:prompt])
    )

    case get_api_key() do
      {:ok, api_key} ->
        body = build_request_body(model_id, Map.new(opts))

        case submit_to_queue(api_key, model_id, body) do
          {:ok, queue_info} ->
            poll_for_completion(api_key, queue_info, on_status, 1)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Submit returns a queue_info map with convenience URLs from Fal's response
  defp submit_to_queue(api_key, model_id, body) do
    url = "#{@queue_base_url}/#{model_id}"
    headers = build_headers(api_key)

    Logger.info("FalClient submitting to queue",
      model: model_id,
      url: url,
      body_keys: Map.keys(body),
      generate_audio: body["generate_audio"]
    )

    case Req.post(url, json: body, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: status, body: response_body}} when status in [200, 201] ->
        case response_body do
          %{"request_id" => request_id} ->
            Logger.info("FalClient request queued", request_id: request_id, model: model_id)

            # Use convenience URLs from response, fall back to constructed URLs
            {:ok,
             %{
               request_id: request_id,
               status_url:
                 response_body["status_url"] ||
                   "#{@queue_base_url}/#{model_id}/requests/#{request_id}/status",
               response_url:
                 response_body["response_url"] ||
                   "#{@queue_base_url}/#{model_id}/requests/#{request_id}"
             }}

          _ ->
            Logger.error("FalClient unexpected queue response", response: inspect(response_body))
            {:error, {:unexpected_response, response_body}}
        end

      {:ok, %{status: status, body: error_body}} ->
        Logger.error("FalClient queue submission error",
          status: status,
          error: inspect(error_body)
        )

        {:error, {:api_error, status, error_body}}

      {:error, error} ->
        Logger.error("FalClient queue submission request failed", error: inspect(error))
        {:error, error}
    end
  end

  defp poll_for_completion(_api_key, _queue_info, _on_status, attempt)
       when attempt > @max_poll_attempts do
    {:error, :timeout}
  end

  defp poll_for_completion(api_key, queue_info, on_status, attempt) do
    headers = build_headers(api_key)

    case Req.get(queue_info.status_url, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: status, body: response_body}} when status in [200, 202] ->
        handle_status_response(api_key, queue_info, response_body, on_status, attempt)

      {:ok, %{status: status, body: error_body}} ->
        Logger.error("FalClient status poll error",
          status: status,
          error: inspect(error_body),
          url: queue_info.status_url
        )

        {:error, {:api_error, status, error_body}}

      {:error, error} ->
        Logger.error("FalClient status poll request failed", error: inspect(error))
        {:error, error}
    end
  end

  defp handle_status_response(api_key, queue_info, response, on_status, attempt) do
    status = response["status"]

    Logger.info("FalClient poll status",
      request_id: queue_info.request_id,
      status: status,
      attempt: "#{attempt}/#{@max_poll_attempts}"
    )

    if on_status, do: on_status.(status, attempt)

    case status do
      "COMPLETED" ->
        case response["error"] do
          nil ->
            fetch_result(api_key, queue_info)

          error ->
            Logger.error("FalClient generation completed with error", error: inspect(error))
            {:error, {:generation_failed, error}}
        end

      status when status in ["IN_QUEUE", "IN_PROGRESS"] ->
        Process.sleep(@poll_interval_ms)
        poll_for_completion(api_key, queue_info, on_status, attempt + 1)

      unknown_status ->
        Logger.warning("FalClient unknown status: #{inspect(unknown_status)}",
          request_id: queue_info.request_id,
          response: inspect(response, limit: 500)
        )

        {:error, {:unknown_status, unknown_status}}
    end
  end

  defp fetch_result(api_key, queue_info) do
    headers = build_headers(api_key)

    Logger.debug("FalClient fetching result",
      request_id: queue_info.request_id,
      url: queue_info.response_url
    )

    case Req.get(queue_info.response_url, headers: headers, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: response_body}} ->
        parse_result(response_body)

      {:ok, %{status: status, body: error_body}} ->
        Logger.error("FalClient result fetch error", status: status, error: inspect(error_body))
        {:error, {:api_error, status, error_body}}

      {:error, error} ->
        Logger.error("FalClient result fetch request failed", error: inspect(error))
        {:error, error}
    end
  end

  defp parse_result(response) do
    video = response["video"] || %{}
    video_url = video["url"]

    if video_url do
      Logger.info("FalClient video generation complete", video_url: video_url)

      {:ok,
       %{
         text: "",
         videos: [%{"type" => "video", "url" => video_url}],
         images: [],
         usage: %{}
       }}
    else
      Logger.error("FalClient no video URL in response", response: inspect(response))
      {:error, :no_video_url}
    end
  end

  # ---------------------------------------------------------------------------
  # Private: Request body helpers
  # ---------------------------------------------------------------------------

  # Body-first arg for pipeline use. nil duration → leave body unchanged.
  defp put_duration(body, _model_id, nil), do: body

  defp put_duration(body, model_id, duration) do
    cond do
      veo_model?(model_id) -> Map.put(body, "duration", "#{duration}s")
      sora_model?(model_id) -> Map.put(body, "duration", duration)
      seedance_model?(model_id) -> Map.put(body, "duration", "#{duration}")
      true -> Map.put(body, "duration", duration)
    end
  end

  # Always set generate_audio for Veo models, defaulting to false
  defp maybe_put_generate_audio(body, model_id, value) do
    if veo_model?(model_id) do
      Map.put(body, "generate_audio", value || false)
    else
      body
    end
  end

  defp maybe_put_string(body, _key, nil), do: body
  defp maybe_put_string(body, key, value), do: Map.put(body, key, value)

  # ---------------------------------------------------------------------------
  # Private: Model family detection
  # ---------------------------------------------------------------------------

  defp veo_model?(model_id), do: String.contains?(model_id, "veo3.1")
  defp sora_model?(model_id), do: String.contains?(model_id, "sora-2")
  defp seedance_model?(model_id), do: String.contains?(model_id, "seedance")

  # ---------------------------------------------------------------------------
  # Private: Message parsing
  # ---------------------------------------------------------------------------

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
    Enum.find_value(content, fn
      # External URLs
      %{type: :image, url: url} when is_binary(url) ->
        url

      %{type: "image", url: url} when is_binary(url) ->
        url

      %{"type" => "image", "url" => url} when is_binary(url) ->
        url

      %{type: :image_url, image_url: %{url: url}} when is_binary(url) ->
        url

      %{"type" => "image_url", "image_url" => %{"url" => url}} when is_binary(url) ->
        url

      # Data URIs (passed through — Fal accepts them natively)
      %{type: :image_url, image_url: %{url: "data:" <> _ = data_url}} ->
        data_url

      %{"type" => "image_url", "image_url" => %{"url" => "data:" <> _ = data_url}} ->
        data_url

      # Raw binary data from ContentPart structs — construct data URI for Fal
      %{type: :image, media_type: mime, data: data} when is_binary(data) ->
        "data:#{mime};base64,#{Base.encode64(data)}"

      %{type: "image", media_type: mime, data: data} when is_binary(data) ->
        "data:#{mime};base64,#{Base.encode64(data)}"

      %{"type" => "image", "media_type" => mime, "data" => data} when is_binary(data) ->
        "data:#{mime};base64,#{Base.encode64(data)}"

      _ ->
        nil
    end)
  end

  defp extract_image_url(_), do: nil

  # ---------------------------------------------------------------------------
  # Private: HTTP helpers
  # ---------------------------------------------------------------------------

  defp get_api_key do
    case System.get_env("FAL_KEY") do
      nil ->
        Logger.error("FAL_KEY not set")
        {:error, :missing_api_key}

      key ->
        {:ok, key}
    end
  end

  defp build_headers(api_key) do
    [
      {"Authorization", "Key #{api_key}"},
      {"Content-Type", "application/json"}
    ]
  end
end
