defmodule Magus.Agents.Support.ToolCallTextTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Support.ToolCallText

  test "extracts tool calls from <function_calls> payload" do
    text =
      "I'll roll 2d10 for you.\n<function_calls>[{\"tool_name\":\"roll_dice\",\"arguments\":{\"notation\":\"2d10\"}}]</function_calls>"

    {clean_text, calls} = ToolCallText.extract_pseudo_tool_calls(text)

    assert clean_text == "I'll roll 2d10 for you."

    assert [
             %{
               name: "roll_dice",
               arguments: %{"notation" => "2d10"}
             }
           ] = calls
  end

  test "extracts tool calls from escaped inline JSON payload" do
    text =
      "I'll create the draft for you.\n[{\\\"tool_name\\\":\\\"write_draft\\\",\\\"arguments\\\":{\\\"title\\\":\\\"The History\\\"}}]"

    {clean_text, calls} = ToolCallText.extract_pseudo_tool_calls(text)

    assert clean_text == "I'll create the draft for you."

    assert [
             %{
               name: "write_draft",
               arguments: %{"title" => "The History"}
             }
           ] = calls
  end

  test "extracts nested function-name tool call shape" do
    text =
      "Let's fetch it. <tool_calls>[{\"id\":\"call_1\",\"function\":{\"name\":\"web_fetch\"},\"arguments\":{\"url\":\"https://example.com\"}}]</tool_calls>"

    {clean_text, calls} = ToolCallText.extract_pseudo_tool_calls(text)

    assert clean_text == "Let's fetch it."

    assert [
             %{
               id: "call_1",
               name: "web_fetch",
               arguments: %{"url" => "https://example.com"}
             }
           ] = calls
  end

  test "falls back to tool-name extraction when arguments JSON is malformed" do
    text =
      "I'll create the draft.\n<function_calls>[{\"tool_name\":\"write_draft\",\"arguments\":\"{\"title\":\"History\"\"}]</function_calls>"

    {clean_text, calls} = ToolCallText.extract_pseudo_tool_calls(text)

    assert clean_text == "I'll create the draft."

    assert [
             %{
               name: "write_draft",
               arguments: %{"__parse_error__" => true}
             }
           ] = calls
  end

  test "returns unchanged text when no pseudo tool payload is present" do
    text = "I can help you with that directly."

    assert {^text, []} = ToolCallText.extract_pseudo_tool_calls(text)
  end
end
