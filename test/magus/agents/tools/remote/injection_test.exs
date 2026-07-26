defmodule Magus.Agents.Tools.Remote.InjectionTest do
  use ExUnit.Case, async: true
  alias Magus.Agents.Tools.Remote.{Injection, ReadFile}

  test "appends resolved local tools to the existing toolset and merges caller id" do
    signal = %{tools: [SomeAgentTool], tool_context: %{user_id: "u1", conversation_id: "c1"}}
    out = Injection.augment(signal, %{local_tools: ["read_file"], caller_session_id: "s1"})

    assert SomeAgentTool in out.tools
    assert ReadFile in out.tools
    assert out.tool_context == %{user_id: "u1", conversation_id: "c1", caller_session_id: "s1"}
  end

  test "is a no-op without local tools or caller session" do
    signal = %{tools: [SomeAgentTool]}
    assert Injection.augment(signal, %{}) == signal
  end

  test "sets tools/context when none existed yet" do
    out = Injection.augment(%{}, %{local_tools: ["read_file"], caller_session_id: "s1"})
    assert out.tools == [ReadFile]
    assert out.tool_context == %{caller_session_id: "s1"}
  end

  test "drops unknown tool names but still records the caller session" do
    out =
      Injection.augment(%{tools: []}, %{local_tools: ["exec_command"], caller_session_id: "s1"})

    assert out.tools == []
    assert out.tool_context == %{caller_session_id: "s1"}
  end

  test "reads string-keyed data too" do
    out = Injection.augment(%{}, %{"local_tools" => ["read_file"], "caller_session_id" => "s1"})
    assert out.tools == [ReadFile]
    assert out.tool_context == %{caller_session_id: "s1"}
  end
end
