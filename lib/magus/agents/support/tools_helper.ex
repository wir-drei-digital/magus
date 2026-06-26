defmodule Magus.Agents.Support.ToolsHelper do
  @moduledoc """
  Utility functions for processing tool calls from LLM streaming responses.

  During streaming, tool call arguments arrive in fragments via `:meta` chunks
  rather than directly on the `:tool_call` chunk. This module handles the
  accumulation and merging of these fragments into complete tool calls.
  """

  require Logger

  @doc """
  Extracts tool calls from a list of stream chunks, merging argument fragments.

  Tool calls in streaming responses arrive in two parts:
  - `:tool_call` chunks contain the tool name and ID, but empty arguments
  - `:meta` chunks contain `tool_call_args: %{index: _, fragment: _}` with JSON fragments

  This function collects both, accumulates the JSON fragments by index,
  parses them, and merges the complete arguments back into the tool calls.

  ## Parameters

    - `chunks` - List of `ReqLLM.StreamChunk` structs from the stream

  ## Returns

  A list of tool call maps with the structure:
  ```
  %{
    id: String.t(),
    name: String.t(),
    arguments: map(),
    index: integer()
  }
  ```

  ## Example

      chunks = Enum.to_list(stream_response.stream)
      tool_calls = ToolsHelper.extract_tool_calls_from_chunks(chunks)
      #=> [%{id: "call_123", name: "roll_dice", arguments: %{"dice" => "2d6"}, index: 0}]

  """
  @spec extract_tool_calls_from_chunks([struct()]) :: [map()]
  def extract_tool_calls_from_chunks(chunks) do
    base_tool_calls = extract_base_tool_calls(chunks)
    arg_fragments = collect_argument_fragments(chunks)

    tool_calls = merge_arguments(base_tool_calls, arg_fragments)

    # Filter out empty/invalid tool calls (some LLMs emit tool_call chunks with nil names)
    Enum.filter(tool_calls, fn tc ->
      is_binary(tc.name) and tc.name != ""
    end)
  end

  # Extract base tool call info from :tool_call chunks
  defp extract_base_tool_calls(chunks) do
    chunks
    |> Enum.filter(&(&1.type == :tool_call))
    |> Enum.map(fn chunk ->
      %{
        id: Map.get(chunk.metadata || %{}, :id) || "call_#{:erlang.unique_integer([:positive])}",
        name: chunk.name,
        arguments: chunk.arguments || %{},
        index: Map.get(chunk.metadata || %{}, :index, 0)
      }
    end)
  end

  # Collect argument JSON fragments from :meta chunks, grouped by tool call index
  defp collect_argument_fragments(chunks) do
    chunks
    |> Enum.filter(&(&1.type == :meta))
    |> Enum.filter(fn chunk ->
      Map.has_key?(chunk.metadata || %{}, :tool_call_args)
    end)
    |> Enum.group_by(fn chunk -> chunk.metadata.tool_call_args.index end)
    |> Map.new(fn {index, fragments} ->
      json =
        fragments
        |> Enum.map_join("", & &1.metadata.tool_call_args.fragment)

      {index, json}
    end)
  end

  # Merge accumulated JSON arguments back into tool calls
  defp merge_arguments(tool_calls, arg_fragments) do
    Enum.map(tool_calls, fn tool_call ->
      case Map.get(arg_fragments, tool_call.index) do
        nil ->
          tool_call

        json_string ->
          trimmed = String.trim(json_string)

          if trimmed == "" do
            # Empty argument string (e.g., no-argument tools) — keep defaults
            tool_call
          else
            case Jason.decode(trimmed) do
              {:ok, args} ->
                %{tool_call | arguments: args}

              {:error, _} ->
                Logger.warning(
                  "Failed to parse tool call arguments for #{tool_call.name}: " <>
                    String.slice(trimmed, 0..200)
                )

                %{tool_call | arguments: :parse_error}
            end
          end
      end
    end)
  end
end
