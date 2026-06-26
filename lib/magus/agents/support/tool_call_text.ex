defmodule Magus.Agents.Support.ToolCallText do
  @moduledoc false

  @function_calls_block ~r/<function_calls>.*?<\/function_calls>/s
  @tool_calls_block ~r/<tool_calls>.*?<\/tool_calls>/s
  @function_calls_capture ~r/<function_calls>\s*(.*?)\s*<\/function_calls>/s
  @tool_calls_capture ~r/<tool_calls>\s*(.*?)\s*<\/tool_calls>/s
  @open_function_calls ~r/\s*<function_calls>.*$/s
  @open_tool_calls ~r/\s*<tool_calls>.*$/s
  @json_tool_calls ~r/\n?\s*\[\s*\{\s*(?:"tool_name"|\\\"tool_name\\\")\s*:.*$/s
  @tool_name_key ~r/(?:\"|\\\")tool_name(?:\"|\\\")/
  @arguments_key ~r/(?:\"|\\\")arguments(?:\"|\\\")/
  @parse_error_args %{"__parse_error__" => true}

  @doc "Returns true when text appears to contain pseudo/native-tool markup leaked into assistant text."
  @spec pseudo_tool_payload?(term()) :: boolean()
  def pseudo_tool_payload?(text) when is_binary(text) and text != "" do
    has_markup_tags? =
      String.contains?(text, "<function_calls>") or
        String.contains?(text, "</function_calls>") or
        String.contains?(text, "<tool_calls>") or
        String.contains?(text, "</tool_calls>")

    has_json_payload_keys? =
      Regex.match?(@tool_name_key, text) and Regex.match?(@arguments_key, text)

    has_markup_tags? or has_json_payload_keys?
  end

  def pseudo_tool_payload?(_), do: false

  @doc "Strips pseudo tool-call payloads from assistant text, preserving any natural-language preface."
  @spec strip_pseudo_tool_payload(term()) :: String.t()
  def strip_pseudo_tool_payload(text) when is_binary(text) and text != "" do
    text
    |> String.replace(@function_calls_block, "")
    |> String.replace(@tool_calls_block, "")
    |> strip_after(@open_function_calls)
    |> strip_after(@open_tool_calls)
    |> strip_after(@json_tool_calls)
    |> String.trim_trailing()
  end

  def strip_pseudo_tool_payload(_), do: ""

  defp strip_after(text, pattern), do: Regex.replace(pattern, text, "")

  @doc """
  Extracts pseudo tool calls from assistant text.

  Returns `{clean_text, tool_calls}` where `tool_calls` is normalized to:
  `%{name: String.t(), arguments: map(), id: optional(String.t())}`.
  """
  @spec extract_pseudo_tool_calls(term()) :: {String.t(), [map()]}
  def extract_pseudo_tool_calls(text) when is_binary(text) and text != "" do
    if pseudo_tool_payload?(text) do
      calls =
        text
        |> extraction_candidates()
        |> Enum.flat_map(&decode_candidate_calls/1)
        |> normalize_calls()
        |> prefer_non_parse_error_calls()
        |> Enum.uniq_by(fn call -> {call[:name], call[:arguments]} end)

      case calls do
        [] -> {text, []}
        _ -> {strip_pseudo_tool_payload(text), calls}
      end
    else
      {text, []}
    end
  end

  def extract_pseudo_tool_calls(_), do: {"", []}

  defp extraction_candidates(text) do
    tagged =
      [@function_calls_capture, @tool_calls_capture]
      |> Enum.flat_map(fn pattern ->
        Regex.scan(pattern, text, capture: :all_but_first)
      end)
      |> List.flatten()

    inline =
      case extract_inline_array_candidate(text) do
        nil -> []
        value -> [value]
      end

    inline_regex =
      case Regex.run(@json_tool_calls, text) do
        [match] -> [String.trim(match)]
        _ -> []
      end

    tagged ++ inline ++ inline_regex
  end

  defp decode_candidate_calls(candidate) when is_binary(candidate) do
    trimmed = String.trim(candidate)

    case trimmed |> decode_candidate_json() |> calls_from_decoded() do
      [] -> extract_calls_by_tool_name(trimmed)
      calls -> calls
    end
  end

  defp decode_candidate_calls(_), do: []

  defp decode_candidate_json(candidate) when is_binary(candidate) and candidate != "" do
    cleaned = candidate |> strip_code_fence() |> String.trim()

    decoded =
      case Jason.decode(cleaned) do
        {:ok, value} -> value
        _ -> decode_with_unescape(cleaned)
      end

    maybe_decode_nested_json(decoded)
  end

  defp decode_candidate_json(_), do: nil

  defp decode_with_unescape(cleaned) do
    unescaped =
      cleaned
      |> String.replace("\\n", "\n")
      |> String.replace("\\\"", "\"")

    case Jason.decode(unescaped) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp maybe_decode_nested_json(decoded) when is_binary(decoded) do
    trimmed = String.trim(decoded)

    if String.starts_with?(trimmed, "[") or String.starts_with?(trimmed, "{") do
      case Jason.decode(trimmed) do
        {:ok, nested} -> nested
        _ -> decoded
      end
    else
      decoded
    end
  end

  defp maybe_decode_nested_json(decoded), do: decoded

  defp calls_from_decoded(decoded) when is_list(decoded), do: decoded

  defp calls_from_decoded(%{} = decoded) do
    cond do
      is_list(decoded["tool_calls"]) -> decoded["tool_calls"]
      is_list(decoded[:tool_calls]) -> decoded[:tool_calls]
      is_list(decoded["function_calls"]) -> decoded["function_calls"]
      is_list(decoded[:function_calls]) -> decoded[:function_calls]
      true -> [decoded]
    end
  end

  defp calls_from_decoded(_), do: []

  defp normalize_calls(calls) when is_list(calls) do
    calls
    |> Enum.map(&normalize_call/1)
    |> Enum.reject(&is_nil/1)
  end

  defp normalize_calls(_), do: []

  defp normalize_call(%{} = call) do
    name =
      fetch_key(call, :tool_name) ||
        fetch_key(call, :name) ||
        fetch_nested_tool_name(call)

    arguments =
      call
      |> fetch_key(:arguments)
      |> normalize_arguments()

    if is_binary(name) and name != "" do
      %{
        id: fetch_key(call, :id),
        name: name,
        arguments: arguments
      }
    end
  end

  defp normalize_call(_), do: nil

  defp fetch_nested_tool_name(call) when is_map(call) do
    case fetch_key(call, :function) do
      %{} = function -> fetch_key(function, :name)
      _ -> nil
    end
  end

  defp fetch_key(map, key) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end

  defp normalize_arguments(%{} = args), do: args

  defp normalize_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{} = decoded} ->
        decoded

      _ ->
        trimmed = String.trim(args)

        if String.starts_with?(trimmed, "{") or String.starts_with?(trimmed, "[") do
          Map.put(@parse_error_args, "__raw__", args)
        else
          %{"value" => args}
        end
    end
  end

  defp normalize_arguments(:parse_error), do: @parse_error_args
  defp normalize_arguments(_), do: %{}

  defp prefer_non_parse_error_calls(calls) when is_list(calls) do
    {grouped, order} =
      Enum.reduce(calls, {%{}, []}, fn call, {acc_groups, acc_order} ->
        name = call[:name]

        groups = Map.update(acc_groups, name, [call], &(&1 ++ [call]))
        order = if name in acc_order, do: acc_order, else: acc_order ++ [name]
        {groups, order}
      end)

    Enum.flat_map(order, fn name ->
      grouped_calls = Map.get(grouped, name, [])
      parsed = Enum.reject(grouped_calls, &parse_error_arguments?(&1[:arguments]))

      if parsed == [] do
        grouped_calls
      else
        parsed
      end
    end)
  end

  defp prefer_non_parse_error_calls(_), do: []

  defp parse_error_arguments?(arguments) when is_map(arguments) do
    Map.get(arguments, "__parse_error__") == true || Map.get(arguments, :__parse_error__) == true
  end

  defp parse_error_arguments?(_), do: false

  defp extract_calls_by_tool_name(candidate) when is_binary(candidate) do
    Regex.scan(
      ~r/(?:\"|\\\")tool_name(?:\"|\\\")\s*:\s*(?:\"|\\\")([^\"\\]+)(?:\"|\\\")/,
      candidate
    )
    |> Enum.map(fn [_, name] ->
      %{
        "tool_name" => name,
        "arguments" => :parse_error
      }
    end)
  end

  defp extract_calls_by_tool_name(_), do: []

  defp strip_code_fence(text) do
    text
    |> String.trim()
    |> String.trim_leading("```json")
    |> String.trim_leading("```")
    |> String.trim_trailing("```")
    |> String.trim()
  end

  defp extract_inline_array_candidate(text) when is_binary(text) do
    with {:ok, tool_name_index} <- find_tool_name_index(text),
         {:ok, array_start} <- find_array_start_before(text, tool_name_index),
         {:ok, array_end} <- find_matching_array_end(text, array_start) do
      String.slice(text, array_start..array_end)
    else
      _ -> nil
    end
  end

  defp extract_inline_array_candidate(_), do: nil

  defp find_tool_name_index(text) do
    cond do
      (match = :binary.match(text, "\"tool_name\"")) != :nomatch ->
        {index, _} = match
        {:ok, index}

      (match = :binary.match(text, "\\\"tool_name\\\"")) != :nomatch ->
        {index, _} = match
        {:ok, index}

      true ->
        :error
    end
  end

  defp find_array_start_before(text, index) when is_integer(index) and index >= 0 do
    prefix = binary_part(text, 0, index + 1)

    case :binary.matches(prefix, "[") do
      [] ->
        :error

      matches ->
        {start, _len} = List.last(matches)
        {:ok, start}
    end
  end

  defp find_matching_array_end(text, start_index) do
    bytes = :binary.bin_to_list(text)

    Enum.with_index(bytes)
    |> Enum.drop(start_index)
    |> Enum.reduce_while({:error, 0, false, false}, fn {byte, idx},
                                                       {_result, depth, in_string, escaped} ->
      cond do
        in_string and escaped ->
          {:cont, {:error, depth, true, false}}

        in_string and byte == ?\\ ->
          {:cont, {:error, depth, true, true}}

        byte == ?" ->
          {:cont, {:error, depth, not in_string, false}}

        in_string ->
          {:cont, {:error, depth, true, false}}

        byte == ?[ ->
          {:cont, {:error, depth + 1, false, false}}

        byte == ?] and depth > 0 ->
          next_depth = depth - 1

          if next_depth == 0 do
            {:halt, {{:ok, idx}, next_depth, false, false}}
          else
            {:cont, {:error, next_depth, false, false}}
          end

        true ->
          {:cont, {:error, depth, false, false}}
      end
    end)
    |> elem(0)
  end
end
