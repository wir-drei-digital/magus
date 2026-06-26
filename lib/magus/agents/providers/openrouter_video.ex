defmodule Magus.Agents.Providers.OpenRouterVideo do
  @moduledoc """
  OpenRouter video generation via the native async videos API.

  Flow:
  1. POST /api/v1/videos        -> {id, polling_url, status}
  2. GET  polling_url (repeat)  -> status: completed | failed, usage.cost, unsigned_urls
  3. GET  content url (auth)    -> raw MP4 bytes

  Returns the result shape expected by `Magus.Agents.Actions.GenerateVideo`:
  `{:ok, %{text: "", videos: [%{"content" => bytes, "mime_type" => "video/mp4"}],
           images: [], usage: %{"cost" => cost}, duration: d}}`.
  """

  @behaviour Magus.Agents.Clients.OpenRouterVideoBehaviour

  require Logger

  @base_url "https://openrouter.ai/api/v1/videos"
  @poll_interval_ms 5_000
  # ~10 minutes total budget (120 attempts x 5s); long enough for slow renders.
  @max_poll_attempts 120

  @doc """
  Builds the POST body for the videos endpoint. Only includes keys that are set.
  `image_url` (when present) becomes a `frame_images` first-frame entry.
  Public for unit testing.
  """
  @spec build_request_body(String.t(), keyword()) :: map()
  def build_request_body(model_id, opts) do
    %{"model" => model_id, "prompt" => opts[:prompt] || "Generate a video"}
    |> put_if("duration", opts[:duration])
    |> put_if("resolution", opts[:resolution])
    |> put_if("aspect_ratio", opts[:aspect_ratio])
    |> put_if("generate_audio", opts[:generate_audio])
    |> put_frame_images(opts[:image_url])
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp put_frame_images(map, nil), do: map

  defp put_frame_images(map, url) do
    Map.put(map, "frame_images", [
      %{"type" => "image_url", "image_url" => %{"url" => url}, "frame_type" => "first_frame"}
    ])
  end

  @impl true
  def chat(messages, opts) do
    {prompt, extracted_image} = extract_prompt_and_image(messages)
    image_url = opts[:image_url] || extracted_image

    gen_opts =
      opts
      |> Keyword.put(:prompt, prompt)
      |> then(fn o -> if image_url, do: Keyword.put(o, :image_url, image_url), else: o end)

    model_id = Keyword.fetch!(opts, :model)

    case System.get_env("OPENROUTER_API_KEY") do
      nil ->
        Logger.error("OPENROUTER_API_KEY not set")
        {:error, :missing_api_key}

      api_key ->
        with {:ok, job} <- submit(api_key, build_request_body(model_id, gen_opts)),
             {:ok, completed} <- poll(api_key, job["polling_url"], 1),
             {:ok, bytes} <- download(api_key, content_url(completed, job)) do
          {:ok,
           %{
             text: "",
             videos: [%{"content" => bytes, "mime_type" => "video/mp4"}],
             images: [],
             usage: completed["usage"] || %{},
             duration: opts[:duration]
           }}
        end
    end
  end

  # --- HTTP pipeline ---

  defp submit(api_key, body) do
    case Req.post(@base_url, [json: body, headers: headers(api_key)] ++ req_options()) do
      {:ok, %{status: status, body: %{"polling_url" => _} = resp}}
      when status in [200, 201, 202] ->
        {:ok, resp}

      {:ok, %{status: status, body: resp}} ->
        Logger.error("OpenRouterVideo submit failed", status: status, body: inspect(resp))
        {:error, {:api_error, status, resp}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp poll(_api_key, _url, attempt) when attempt > @max_poll_attempts, do: {:error, :timeout}

  defp poll(api_key, url, attempt) do
    case Req.get(url, [headers: headers(api_key)] ++ req_options()) do
      {:ok, %{status: status, body: %{"status" => "completed"} = resp}}
      when status in [200, 202] ->
        {:ok, resp}

      {:ok, %{body: %{"status" => "failed"} = resp}} ->
        {:error, {:generation_failed, resp["error"] || "failed"}}

      # Any other non-terminal status on a 2xx response (e.g. "queued",
      # "pending", "in_progress") means the job is still rendering: keep polling.
      {:ok, %{status: status, body: %{"status" => s}}}
      when status in [200, 202] and is_binary(s) ->
        Process.sleep(@poll_interval_ms)
        poll(api_key, url, attempt + 1)

      {:ok, %{status: status, body: resp}} ->
        {:error, {:api_error, status, resp}}

      {:error, error} ->
        {:error, error}
    end
  end

  defp download(api_key, url) do
    case Req.get(url, [headers: headers(api_key)] ++ req_options()) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status, body: body}} -> {:error, {:download_failed, status, body}}
      {:error, error} -> {:error, error}
    end
  end

  # Prefer the provider-supplied download URL; fall back to constructing it.
  defp content_url(%{"unsigned_urls" => [url | _]}, _job) when is_binary(url), do: url
  defp content_url(_completed, %{"id" => id}), do: "#{@base_url}/#{id}/content?index=0"

  defp headers(api_key) do
    [
      {"Authorization", "Bearer #{api_key}"},
      {"Content-Type", "application/json"},
      {"HTTP-Referer", Application.get_env(:magus, :app_url, "http://localhost:4000")},
      {"X-Title", "Magus"}
    ]
  end

  # A generous default receive_timeout (video submits and multi-MB MP4 downloads
  # can be slow) placed first so a test-supplied `plug:` and any env override
  # still take effect. Req merges later keys over earlier ones.
  defp req_options do
    [receive_timeout: 60_000] ++ Application.get_env(:magus, :openrouter_video_req_options, [])
  end

  # --- Message parsing ---

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
      %{type: :image_url, image_url: %{url: url}} when is_binary(url) ->
        url

      %{"type" => "image_url", "image_url" => %{"url" => url}} when is_binary(url) ->
        url

      %{type: :image, media_type: mime, data: data} when is_binary(data) ->
        "data:#{mime};base64,#{Base.encode64(data)}"

      _ ->
        nil
    end)
  end

  defp extract_image_url(_), do: nil
end
