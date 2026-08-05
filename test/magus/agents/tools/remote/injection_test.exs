defmodule Magus.Agents.Tools.Remote.InjectionTest do
  use ExUnit.Case, async: true
  alias Magus.Agents.Tools.Remote.{Injection, ReadFile}

  test "appends resolved local tools to the existing toolset" do
    signal = %{tools: [SomeAgentTool], tool_context: %{user_id: "u1"}}
    out = Injection.augment(signal, %{local_tools: ["read_file"]})

    assert out.tools == [SomeAgentTool, ReadFile]
    # tool_context is untouched — routing identity comes from acting_user_id,
    # which Preflight already puts into every tool context
    assert out.tool_context == %{user_id: "u1"}
  end

  test "is a no-op without local tools" do
    signal = %{tools: [SomeAgentTool]}
    assert Injection.augment(signal, %{}) == signal
  end

  test "is a no-op when the base toolset is an explicit empty list (non-tool model)" do
    signal = %{tools: []}
    assert Injection.augment(signal, %{local_tools: ["read_file"]}) == signal
  end

  test "is a no-op when the base toolset is absent (degraded preflight context)" do
    assert Injection.augment(%{}, %{local_tools: ["read_file"]}) == %{}
  end

  test "drops unknown tool names" do
    signal = %{tools: [SomeAgentTool]}
    assert Injection.augment(signal, %{local_tools: ["exec_command"]}) == signal
  end

  test "reads string-keyed data too" do
    out = Injection.augment(%{tools: [SomeAgentTool]}, %{"local_tools" => ["read_file"]})
    assert out.tools == [SomeAgentTool, ReadFile]
  end

  test "never threads a caller_session_id from data into tool_context" do
    signal = %{tools: [SomeAgentTool], tool_context: %{user_id: "u1"}}

    out =
      Injection.augment(signal, %{
        :local_tools => ["read_file"],
        :caller_session_id => "victim-key",
        "caller_session_id" => "victim-key"
      })

    assert out.tool_context == %{user_id: "u1"}
  end
end
