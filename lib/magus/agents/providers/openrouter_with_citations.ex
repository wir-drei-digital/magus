defmodule Magus.Agents.Providers.OpenRouterWithCitations do
  @moduledoc """
  Custom OpenRouter provider that uses the Responses API with web search plugin
  to get citations from Perplexity Sonar models.

  OpenRouter's Responses API (`/api/v1/responses`) supports a `web` plugin that
  returns `url_citation` annotations on text output items. This provider encodes
  requests in the Responses API format and extracts those annotations as citations.

  ## Usage

  Register this provider and use it for Perplexity Sonar models:

      # In your model configuration
      %{provider: :openrouter_citations, model_id: "perplexity/sonar-pro-search"}

  Citations will be available in the streaming metadata:

      metadata = StreamResponse.MetadataHandle.await(stream_response.metadata_handle)
      citations = Map.get(metadata, :citations, [])

  """

  use ReqLLM.Provider,
    id: :openrouter_citations,
    default_base_url: "https://openrouter.ai/api/v1",
    default_env_key: "OPENROUTER_API_KEY"

  require Logger

  alias ReqLLM.Providers.OpenAI.ResponsesAPI

  # Delegate option translation and request preparation to standard OpenRouter
  defdelegate translate_options(operation, model, opts), to: ReqLLM.Providers.OpenRouter

  @doc """
  Attach request/response pipeline steps.

  Uses the standard OpenRouter attach (auth headers, etc.) but our custom
  encode_body and decode_response will be registered as pipeline steps.
  """
  @impl ReqLLM.Provider
  def attach(request, model_input, user_opts) do
    ReqLLM.Provider.Defaults.default_attach(__MODULE__, request, model_input, user_opts)
  end

  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @doc """
  Encode the request body in Responses API format with web search plugin.
  """
  @impl ReqLLM.Provider
  def encode_body(request) do
    body = build_responses_body(request)
    ReqLLM.Provider.Defaults.encode_body_from_map(request, body)
  end

  @doc """
  Decode non-streaming responses using the Responses API decoder.
  """
  @impl ReqLLM.Provider
  def decode_response(args) do
    ResponsesAPI.decode_response(args)
  end

  @doc """
  Decode streaming events using the Responses API decoder, with custom handling
  for citation annotations from the web search plugin.

  Citations are extracted from the `response.completed` event which contains the
  full response with all output items and their annotations. This avoids emitting
  duplicate citations from intermediate events like `response.output_text.done`.
  """
  @impl ReqLLM.Provider
  def decode_stream_event(%{data: data} = event, model) when is_map(data) do
    event_type =
      Map.get(event, :event) || Map.get(event, "event") || data["event"] || data["type"]

    # Get standard chunks from the Responses API decoder
    standard_chunks = ResponsesAPI.decode_stream_event(event, model)

    # Extract citations only from the completed event (the authoritative source)
    # to avoid duplicates from intermediate events
    citations_chunks =
      case event_type do
        "response.completed" -> extract_citations_from_completed(data)
        _ -> []
      end

    standard_chunks ++ citations_chunks
  end

  def decode_stream_event(%{data: _data} = event, model) do
    ResponsesAPI.decode_stream_event(event, model)
  end

  @doc """
  Build a Finch request for streaming via the Responses API endpoint.
  """
  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    api_key = ReqLLM.Keys.get!(model, opts)

    headers = [
      {"Authorization", "Bearer " <> api_key},
      {"Content-Type", "application/json"},
      {"Accept", "text/event-stream"}
    ]

    base_url = ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, opts)
    url = "#{base_url}/responses"

    # Ensure stream: true is in opts so the body includes "stream": true
    stream_opts =
      if is_list(opts), do: Keyword.put(opts, :stream, true), else: Map.put(opts, :stream, true)

    body = build_responses_body_from_context(model, context, stream_opts)

    {:ok, Finch.build(:post, url, headers, Jason.encode!(body))}
  rescue
    error ->
      {:error,
       ReqLLM.Error.API.Request.exception(
         reason: "Failed to build Responses API streaming request: #{Exception.message(error)}"
       )}
  end

  # --- Private ---

  defp build_responses_body(request) do
    context = request.options[:context] || %ReqLLM.Context{messages: []}
    model_name = request.options[:model] || request.options[:id]
    opts = request.options

    build_responses_body_from_parts(context, model_name, opts)
  end

  defp build_responses_body_from_context(model, context, opts) do
    opts_map = if is_map(opts), do: opts, else: Map.new(opts)
    build_responses_body_from_parts(context, model.id, opts_map)
  end

  # Expects opts_map to already be a map (callers ensure this).
  # Only encodes text messages — scoped to Perplexity Sonar search models
  # which don't use tool call round-trips.
  defp build_responses_body_from_parts(context, model_name, opts_map) do
    input = encode_messages_as_input(context.messages)

    body =
      %{
        "model" => model_name,
        "input" => input,
        "plugins" => [%{"id" => "web"}]
      }

    body =
      if opts_map[:stream] do
        Map.put(body, "stream", true)
      else
        body
      end

    body =
      case opts_map[:max_tokens] || opts_map[:max_output_tokens] do
        nil -> body
        max -> Map.put(body, "max_output_tokens", max)
      end

    body
    |> maybe_put("temperature", opts_map[:temperature])
    |> maybe_put("top_p", opts_map[:top_p])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  @valid_responses_api_roles ~w(user system assistant developer)

  defp encode_messages_as_input(messages) when is_list(messages) do
    Enum.flat_map(messages, fn msg ->
      role =
        case msg do
          %{role: role} when is_atom(role) -> Atom.to_string(role)
          %{"role" => role} when is_binary(role) -> role
          _ -> "user"
        end

      # The Responses API only accepts user/system/assistant/developer roles.
      # Skip tool result messages and any other unsupported roles.
      if role in @valid_responses_api_roles do
        text = extract_message_text(msg)

        if text != "" do
          [%{"role" => role, "content" => text}]
        else
          []
        end
      else
        []
      end
    end)
  end

  defp encode_messages_as_input(_), do: []

  defp extract_message_text(%{content: content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_message_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{text: text} when is_binary(text) -> text
      %{"text" => text} when is_binary(text) -> text
      text when is_binary(text) -> text
      _ -> ""
    end)
    |> Enum.join("")
  end

  defp extract_message_text(%{content: text}) when is_binary(text), do: text
  defp extract_message_text(%{"content" => text}) when is_binary(text), do: text
  defp extract_message_text(_), do: ""

  defp extract_citations_from_completed(data) do
    case get_in(data, ["response", "output"]) do
      output when is_list(output) ->
        citations =
          output
          |> Enum.flat_map(fn item ->
            case item do
              %{"type" => "output_text", "annotations" => annotations}
              when is_list(annotations) ->
                Enum.filter(annotations, fn ann -> ann["type"] == "url_citation" end)
                |> Enum.map(fn ann ->
                  %{
                    url: ann["url"],
                    title: ann["title"],
                    start_index: ann["start_index"],
                    end_index: ann["end_index"]
                  }
                end)

              _ ->
                []
            end
          end)

        if citations != [] do
          [ReqLLM.StreamChunk.meta(%{citations: citations})]
        else
          []
        end

      _ ->
        []
    end
  end
end
