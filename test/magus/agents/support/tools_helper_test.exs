defmodule Magus.Agents.Support.ToolsHelperTest do
  @moduledoc """
  Tests for ToolsHelper, which extracts and merges tool calls from LLM stream chunks.
  """
  use ExUnit.Case, async: true

  alias Magus.Agents.Support.ToolsHelper

  defp tool_call_chunk(name, opts) do
    %{
      type: :tool_call,
      name: name,
      arguments: opts[:arguments] || %{},
      metadata: %{
        id: opts[:id] || "call_#{:erlang.unique_integer([:positive])}",
        index: opts[:index] || 0
      }
    }
  end

  defp meta_chunk(index, fragment) do
    %{
      type: :meta,
      metadata: %{
        tool_call_args: %{index: index, fragment: fragment}
      }
    }
  end

  describe "extract_tool_calls_from_chunks/1" do
    test "parses valid JSON arguments from fragments" do
      chunks = [
        tool_call_chunk("roll_dice", id: "call_1", index: 0),
        meta_chunk(0, ~s({"dice":)),
        meta_chunk(0, ~s( "2d6"}))
      ]

      assert [%{name: "roll_dice", arguments: %{"dice" => "2d6"}}] =
               ToolsHelper.extract_tool_calls_from_chunks(chunks)
    end

    test "sets arguments to :parse_error when JSON is malformed" do
      chunks = [
        tool_call_chunk("sandbox_write_file", id: "call_1", index: 0),
        meta_chunk(0, ~s(\\documentclass[12pt]{article}\\begin{document}Hello\\end{document}))
      ]

      assert [%{name: "sandbox_write_file", arguments: :parse_error}] =
               ToolsHelper.extract_tool_calls_from_chunks(chunks)
    end

    test "filters out tool calls with nil names" do
      chunks = [
        tool_call_chunk(nil, id: "call_1", index: 0)
      ]

      assert [] = ToolsHelper.extract_tool_calls_from_chunks(chunks)
    end

    test "treats empty argument fragments as no arguments" do
      chunks = [
        tool_call_chunk("read_draft", id: "call_1", index: 0),
        meta_chunk(0, ""),
        meta_chunk(0, "")
      ]

      assert [%{name: "read_draft", arguments: %{}}] =
               ToolsHelper.extract_tool_calls_from_chunks(chunks)
    end

    test "treats whitespace-only argument fragments as no arguments" do
      chunks = [
        tool_call_chunk("read_draft", id: "call_1", index: 0),
        meta_chunk(0, "  "),
        meta_chunk(0, "\n")
      ]

      assert [%{name: "read_draft", arguments: %{}}] =
               ToolsHelper.extract_tool_calls_from_chunks(chunks)
    end

    test "handles multiple tool calls with one having malformed arguments" do
      chunks = [
        tool_call_chunk("roll_dice", id: "call_1", index: 0),
        tool_call_chunk("sandbox_write_file", id: "call_2", index: 1),
        meta_chunk(0, ~s({"dice": "1d20"})),
        meta_chunk(1, ~s(not valid json at all))
      ]

      result = ToolsHelper.extract_tool_calls_from_chunks(chunks)

      assert [valid, invalid] = result
      assert valid.name == "roll_dice"
      assert valid.arguments == %{"dice" => "1d20"}
      assert invalid.name == "sandbox_write_file"
      assert invalid.arguments == :parse_error
    end
  end
end
