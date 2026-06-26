defmodule Magus.Chat.Message.Calculations.AsLlmMessage do
  @moduledoc """
  Converts a Message to a ReqLLM.Message struct.

  Handles:
  - User vs agent messages with correct roles
  - Attachments converted to ContentPart structs
  - Multiplayer name prefixing for user messages
  - Reasoning details preservation for agent messages

  Tool-enabled histories are supported:
  - agent messages with `tool_call_data.tool_calls` are converted to assistant
    messages carrying tool_calls
  - event messages with tool result data are converted to tool messages

  ## Options

  - `:is_multiplayer` - Whether to prefix user messages with sender name (default: false)

  ## Usage

      messages = Ash.read!(Message, load: [as_llm_message: [is_multiplayer: true]])
      llm_messages = Enum.map(messages, & &1.as_llm_message)
  """
  use Ash.Resource.Calculation

  require Ash.Query
  import ReqLLM.Context

  alias Magus.Chat.Message.ToolCallHelpers
  alias ReqLLM.Message.ContentPart

  @impl true
  def load(_query, _opts, _context) do
    [
      :text,
      :source,
      :attachments,
      :reasoning_details,
      :tool_call_data,
      :message_type,
      created_by: [:display_name, :email]
    ]
  end

  @impl true
  def calculate(messages, opts, context) do
    args = context.arguments || %{}
    is_multiplayer = arg_or_opt(args, opts, :is_multiplayer, false)
    include_tool_calls = arg_or_opt(args, opts, :include_tool_calls, false)
    actor = context.actor
    Enum.map(messages, &to_llm_message(&1, is_multiplayer, include_tool_calls, actor))
  end

  defp arg_or_opt(args, opts, key, default) do
    case Map.get(args, key) do
      nil -> Keyword.get(opts, key, default)
      val -> val
    end
  end

  defp to_llm_message(%{source: :user} = msg, is_multiplayer, _include_tool_calls, actor) do
    text = format_user_text(msg.text, msg.created_by, is_multiplayer)
    content = build_content(text, msg.attachments, actor)
    user(content)
  end

  defp to_llm_message(
         %{source: :agent, message_type: :event} = msg,
         _is_multiplayer,
         _include_tool_calls,
         _actor
       ) do
    event_to_tool_result(msg)
  end

  defp to_llm_message(%{source: :agent} = msg, _is_multiplayer, include_tool_calls, actor) do
    content = build_content(msg.text, msg.attachments, actor)

    tool_calls =
      if include_tool_calls, do: extract_tool_calls(msg.tool_call_data), else: []

    base_msg =
      if tool_calls == [] do
        assistant(content)
      else
        assistant(content, tool_calls: tool_calls)
      end

    maybe_add_reasoning_details(base_msg, msg.reasoning_details)
  end

  # Skip event messages and other unknown types
  defp to_llm_message(_msg, _is_multiplayer, _include_tool_calls, _actor), do: nil

  defp format_user_text(text, _user, false), do: text

  defp format_user_text(text, user, true) do
    case get_display_name(user) do
      nil -> text
      name -> "[#{name}]: #{text}"
    end
  end

  defp build_content(text, [], _actor), do: text
  defp build_content(text, nil, _actor), do: text

  defp build_content(text, attachment_ids, actor) when is_list(attachment_ids) do
    # Load files paired with their ids so we can prepend a `[file_id: <uuid>]`
    # marker before each attachment part. This lets the LLM reference prior
    # images by file_id in subsequent turns — otherwise it only sees the image
    # bytes via vision and has no textual handle for the UUID, which leads to
    # hallucinated ids when tools like generate_image accept reference_file_ids.
    files =
      Magus.Files.File
      |> Ash.Query.filter(id in ^attachment_ids)
      |> Ash.Query.load(:llm_content_part)
      |> Ash.read!(actor: actor)

    paired =
      files
      |> Enum.map(&{&1.id, &1.llm_content_part})
      |> Enum.reject(fn {_id, part} -> is_nil(part) end)

    if paired == [] do
      text
    else
      attachment_parts =
        Enum.flat_map(paired, fn {id, part} ->
          [ContentPart.text("[file_id: #{id}]"), to_content_part(part)]
        end)

      [ContentPart.text(text)] ++ attachment_parts
    end
  end

  # Convert our internal content part format to a ReqLLM.ContentPart
  defp to_content_part(%{type: :image, media_type: mime, data: base64_data}) do
    # ContentPart.image expects raw binary, not base64
    ContentPart.image(Base.decode64!(base64_data), mime)
  end

  defp to_content_part(%{type: :text, text: text}), do: ContentPart.text(text)
  defp to_content_part(other), do: other

  defp get_display_name(nil), do: nil
  defp get_display_name(%{display_name: name}) when is_binary(name) and name != "", do: name
  defp get_display_name(%{email: email}) when not is_nil(email), do: to_string(email)
  defp get_display_name(_), do: nil

  defp maybe_add_reasoning_details(base_msg, reasoning_details)
       when is_list(reasoning_details) and reasoning_details != [] do
    Map.put(base_msg, :reasoning_details, reasoning_details)
  end

  defp maybe_add_reasoning_details(base_msg, _reasoning_details), do: base_msg

  defp event_to_tool_result(%{tool_call_data: data, text: text}) when is_map(data) do
    tool_call_id =
      ToolCallHelpers.fetch(data, :tool_use_id) || ToolCallHelpers.fetch(data, :tool_call_id)

    tool_name = ToolCallHelpers.fetch(data, :tool_name)
    output = ToolCallHelpers.fetch(data, :output)
    content = normalize_tool_output(output, text)

    if is_binary(tool_call_id) and tool_call_id != "" and is_binary(tool_name) and tool_name != "" do
      tool_result(tool_call_id, tool_name, content)
    else
      nil
    end
  end

  defp event_to_tool_result(_), do: nil

  defp extract_tool_calls(tool_call_data),
    do: ToolCallHelpers.extract_tool_calls(tool_call_data)

  defp normalize_tool_output(nil, fallback) when is_binary(fallback), do: fallback

  defp normalize_tool_output(output, _fallback) when is_binary(output), do: output

  defp normalize_tool_output(output, _fallback) when is_map(output) or is_list(output) do
    case Jason.encode(output) do
      {:ok, json} -> json
      _ -> inspect(output)
    end
  end

  defp normalize_tool_output(_output, fallback) when is_binary(fallback), do: fallback
  defp normalize_tool_output(output, _fallback), do: inspect(output)
end
