defmodule Magus.Agents.Providers.OpenRouterImage do
  @moduledoc """
    This is a workaround until ReqLLM supports image generation for OpenRouter.
  """

  require Logger

  alias Magus.Agents.Config
  alias Magus.Agents.Routing.ModelKey

  @type model_key :: String.t()
  @type context :: ReqLLM.Context.t()

  @doc """
  Generate images via OpenRouter using direct API call.

  Makes a direct HTTP request to OpenRouter with the `modalities` parameter
  since ReqLLM doesn't support this option yet.

  Returns {:ok, %{text: String.t(), images: [map()]}} or {:error, term()}
  """
  @spec generate_image(model_key() | nil, context(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def generate_image(model_key, context, opts \\ []) do
    model = resolve_model(model_key)

    model_id = ModelKey.extract_model_id(model)

    Logger.info("LLM generate_image model_key: #{inspect(model_key)}")

    api_key = System.get_env("OPENROUTER_API_KEY")

    unless api_key do
      Logger.error("OPENROUTER_API_KEY not set")
      {:error, :missing_api_key}
    else
      # messages = format_messages_for_openrouter(context)

      body = build_request_body(model_id, context, opts)

      headers = [
        {"Authorization", "Bearer #{api_key}"},
        {"Content-Type", "application/json"},
        {"HTTP-Referer", Application.get_env(:magus, :app_url, "http://localhost:4000")},
        {"X-Title", "Magus"}
      ]

      case Req.post("https://openrouter.ai/api/v1/chat/completions",
             json: body,
             headers: headers,
             receive_timeout: 120_000
           ) do
        {:ok, %{status: 200, body: response_body}} ->
          parse_image_response(response_body)

        {:ok, %{status: status, body: error_body}} ->
          Logger.error("OpenRouter image generation failed",
            status: status,
            error: inspect(error_body)
          )

          {:error, {:api_error, status, error_body}}

        {:error, error} ->
          Logger.error("OpenRouter image generation request failed", error: inspect(error))
          {:error, error}
      end
    end
  end

  @doc """
  Builds the OpenRouter `/chat/completions` request body for image generation.

  Always sets `modalities: ["image"]` and `usage: %{include: true}` so the
  response carries the real billed `cost`. Public for unit testing.
  """
  @spec build_request_body(String.t(), context(), keyword()) :: map()
  def build_request_body(model_id, context, opts) do
    %{
      model: model_id,
      messages: normalize_messages(context),
      modalities: ["image"],
      usage: %{include: true}
    }
    |> maybe_add_opt(:max_tokens, opts[:max_tokens])
    |> maybe_add_opt(:temperature, opts[:temperature])
    |> maybe_add_image_config(opts[:image_config])
  end

  defp maybe_add_opt(map, _key, nil), do: map
  defp maybe_add_opt(map, key, value), do: Map.put(map, key, value)

  # Convert internal ReqLLM messages/content parts into the OpenAI chat
  # completions shape that OpenRouter expects. Image content parts must be
  # emitted as `{"type": "image_url", "image_url": {"url": "data:...;base64,..."}}`;
  # otherwise the model silently drops them. Exposed (@doc false) only so
  # ad-hoc verification from iex/mix run can inspect the output shape.
  @doc false
  def normalize_messages(messages) when is_list(messages) do
    Enum.map(messages, &normalize_message/1)
  end

  defp normalize_message(%ReqLLM.Message{role: role, content: content}) do
    %{role: to_string(role), content: normalize_content(content)}
  end

  defp normalize_message(%{"role" => _} = msg), do: msg
  defp normalize_message(%{role: _} = msg), do: msg

  defp normalize_content(content) when is_binary(content), do: content

  defp normalize_content(content) when is_list(content) do
    Enum.map(content, &normalize_part/1)
  end

  defp normalize_content(other), do: other

  defp normalize_part(%ReqLLM.Message.ContentPart{type: :text, text: text}) do
    %{type: "text", text: text}
  end

  defp normalize_part(%ReqLLM.Message.ContentPart{
         type: :image,
         data: data,
         media_type: mime
       })
       when is_binary(data) do
    # data is raw binary; wrap in a data URL for OpenAI-compatible shape.
    encoded = Base.encode64(data)
    %{type: "image_url", image_url: %{url: "data:#{mime || "image/png"};base64,#{encoded}"}}
  end

  defp normalize_part(%ReqLLM.Message.ContentPart{type: :image_url, url: url}) do
    %{type: "image_url", image_url: %{url: url}}
  end

  defp normalize_part(part), do: part

  defp maybe_add_image_config(body, nil), do: body

  defp maybe_add_image_config(body, config) when is_map(config) do
    sanitized = Magus.Agents.ImageGenerationConfig.sanitize(config)

    image_config =
      %{}
      |> maybe_add_opt(:aspect_ratio, sanitized["aspect_ratio"])
      |> maybe_add_opt(:image_size, sanitized["image_size"])

    if map_size(image_config) > 0, do: Map.put(body, :image_config, image_config), else: body
  end

  # Parse the OpenRouter response and extract text and images
  defp parse_image_response(%{"choices" => [%{"message" => message} | _]} = response) do
    text = message["content"] || ""

    # Extract images from the response
    # OpenRouter returns images in various formats depending on the model
    images = extract_images_from_message(message)

    {:ok, %{text: text, images: images, usage: response["usage"] || %{}}}
  end

  defp parse_image_response(response) do
    Logger.warning("Unexpected image response format", response: inspect(response))
    {:ok, %{text: "", images: []}}
  end

  # Extract images from message - handles different response formats
  defp extract_images_from_message(message) do
    # Check for images array in the response
    cond do
      # Some models return images as a separate field (e.g., Gemini)
      # Format: %{"images" => [%{"type" => "image_url", "image_url" => %{"url" => "data:..."}}]}
      is_list(message["images"]) ->
        message["images"]
        |> Enum.map(fn img ->
          url = extract_image_url(img)
          if url, do: %{"type" => "image", "data_url" => url}, else: nil
        end)
        |> Enum.reject(&is_nil/1)

      # Check for multipart content with image parts
      is_list(message["content"]) ->
        message["content"]
        |> Enum.filter(fn part ->
          part["type"] == "image" || part["type"] == "image_url"
        end)
        |> Enum.map(fn part ->
          url = extract_image_url(part)
          if url, do: %{"type" => "image", "data_url" => url}, else: nil
        end)
        |> Enum.reject(&is_nil/1)

      true ->
        []
    end
  end

  # Extract URL from various image formats
  defp extract_image_url(%{"image_url" => %{"url" => url}}), do: url
  defp extract_image_url(%{"url" => url}), do: url
  defp extract_image_url(%{"data_url" => url}), do: url

  defp extract_image_url(%{"data" => data, "mime_type" => mime}),
    do: "data:#{mime};base64,#{data}"

  defp extract_image_url(%{"data" => data}), do: "data:image/png;base64,#{data}"
  defp extract_image_url(%{"b64_json" => data}), do: "data:image/png;base64,#{data}"
  defp extract_image_url(_), do: nil

  def resolve_model(nil), do: Config.default_model()
  def resolve_model(key) when is_binary(key), do: key
end
