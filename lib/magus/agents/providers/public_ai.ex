defmodule Magus.Agents.Providers.PublicAI do
  @moduledoc """
  PublicAI provider for Swiss AI Apertus models.

  OpenAI-compatible API with custom User-Agent header requirement.
  Uses the default OpenAI encoding/decoding with minimal overrides.

  ## Configuration

      # Add to .env file
      PUBLIC_AI_API_KEY=your-key-here

  ## Models

  - swiss-ai/apertus-70b-instruct - Multilingual model developed in Switzerland
    - Context Window: 65,536 tokens
    - Max Output: 8,192 tokens
    - Recommended: temperature 0.8, top_p 0.9

  ## Tool Calling

  Note: The Apertus model does not currently support OpenAI-style tool/function calling.
  The model will receive tool definitions but will respond with text instead of tool calls.
  """

  use ReqLLM.Provider,
    id: :publicai,
    default_base_url: "https://api.publicai.co/v1",
    default_env_key: "PUBLIC_AI_API_KEY"

  @default_temperature 0.8
  @default_max_tokens 8192

  @doc """
  Custom attach that adds the required User-Agent header for PublicAI.
  """
  @impl ReqLLM.Provider
  def attach(request, model, opts) do
    # Apply defaults, then add User-Agent header
    request = ReqLLM.Provider.Defaults.default_attach(__MODULE__, request, model, opts)
    Req.Request.put_header(request, "user-agent", "Magus/1.0")
  end

  @doc """
  Translate options to apply Swiss AI recommended defaults.
  """
  @impl ReqLLM.Provider
  def translate_options(_operation, _model, opts) do
    opts =
      opts
      |> Keyword.put_new(:temperature, @default_temperature)
      |> Keyword.put_new(:max_tokens, @default_max_tokens)

    {opts, []}
  end

  # Delegate to default implementation for prepare_request
  @impl ReqLLM.Provider
  def prepare_request(operation, model_spec, input, opts) do
    ReqLLM.Provider.Defaults.prepare_request(__MODULE__, operation, model_spec, input, opts)
  end

  @doc """
  Custom attach_stream that adds the required User-Agent header for streaming requests.

  The default attach_stream builds Finch requests directly without calling attach/3,
  so we need to ensure the User-Agent header is included for PublicAI API compliance.
  """
  @impl ReqLLM.Provider
  def attach_stream(model, context, opts, _finch_name) do
    {translated_opts, _warnings} = translate_options(:chat, model, opts)

    api_key = ReqLLM.Keys.get!(model, translated_opts)
    base_url = ReqLLM.Provider.Options.effective_base_url(__MODULE__, model, translated_opts)

    headers = [
      {"Authorization", "Bearer " <> api_key},
      {"Content-Type", "application/json"},
      {"Accept", "text/event-stream"},
      {"User-Agent", "Magus/1.0"}
    ]

    url = "#{base_url}/chat/completions"

    body = build_streaming_body(model, context, translated_opts)

    finch_request = Finch.build(:post, url, headers, body)
    {:ok, finch_request}
  end

  defp build_streaming_body(model, context, opts) do
    messages = encode_messages(context.messages)

    body =
      %{
        model: model.id,
        messages: messages,
        stream: true,
        stream_options: %{include_usage: true}
      }
      |> maybe_put(:temperature, opts[:temperature])
      |> maybe_put(:max_tokens, opts[:max_tokens])
      |> maybe_put(:top_p, opts[:top_p])

    # Add tools if present (for future compatibility if model gains tool support)
    body =
      case opts[:tools] do
        tools when is_list(tools) and tools != [] ->
          tool_schemas = Enum.map(tools, &ReqLLM.Tool.to_schema(&1, :openai))
          body = Map.put(body, :tools, tool_schemas)

          case opts[:tool_choice] do
            nil -> body
            choice -> Map.put(body, :tool_choice, choice)
          end

        _ ->
          body
      end

    Jason.encode!(body)
  end

  defp encode_messages(messages) do
    Enum.map(messages, fn message ->
      base = %{
        role: to_string(message.role),
        content: encode_content(message.content)
      }

      base
      |> maybe_put(:tool_calls, message.tool_calls)
      |> maybe_put(:tool_call_id, message.tool_call_id)
      |> maybe_put(:name, message.name)
    end)
  end

  defp encode_content(content) when is_binary(content), do: content

  defp encode_content(content) when is_list(content) do
    parts =
      content
      |> Enum.map(&encode_content_part/1)
      |> Enum.reject(&is_nil/1)

    # Flatten single text-only content to string
    case parts do
      [%{type: "text", text: text}] -> text
      _ -> parts
    end
  end

  defp encode_content_part(%{type: :text, text: text}), do: %{type: "text", text: text}
  defp encode_content_part(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
