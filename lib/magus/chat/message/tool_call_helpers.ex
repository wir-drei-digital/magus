defmodule Magus.Chat.Message.ToolCallHelpers do
  @moduledoc """
  Shared helpers for extracting and normalizing tool call data from messages.

  Used by both `AsLlmMessage` (calculation) and `BuildLLMContext` (recovery).
  """

  @doc """
  Extracts tool calls from a message's tool_call_data map.

  Returns a list of `%{id, name, arguments}` maps, filtering out any
  entries with missing id or name.
  """
  def extract_tool_calls(%{} = tool_call_data) do
    calls = fetch(tool_call_data, :tool_calls) || []

    if is_list(calls) do
      calls
      |> Enum.map(fn call ->
        %{
          id: fetch(call, :id),
          name: fetch(call, :name) || fetch(call, :tool_name),
          arguments: normalize_arguments(fetch(call, :arguments))
        }
      end)
      |> Enum.filter(fn call ->
        is_binary(call.id) and call.id != "" and is_binary(call.name) and call.name != ""
      end)
    else
      []
    end
  end

  def extract_tool_calls(_), do: []

  @doc """
  Fetches a value from a map by atom key, falling back to string key.
  """
  def fetch(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  def fetch(_map, _key), do: nil

  @doc """
  Normalizes tool call arguments to a map.
  """
  def normalize_arguments(%{} = args), do: args

  def normalize_arguments(args) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, %{} = decoded} -> decoded
      _ -> %{"value" => args}
    end
  end

  def normalize_arguments(_), do: %{}
end
