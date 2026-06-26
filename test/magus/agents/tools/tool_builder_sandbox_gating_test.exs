defmodule Magus.Agents.Tools.ToolBuilderSandboxGatingTest do
  @moduledoc """
  The sandbox tools are gated on `Magus.Sandbox.Provider.configured?/0`, mirroring
  the web Search/Crawl capability gates: a self-host instance without a sandbox
  provider key must not offer dead sandbox tools.
  """
  # async: false — mutates global :magus app env (the active sandbox provider).
  use Magus.ResourceCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.ToolBuilder
  alias Magus.Chat

  setup do
    original_sandbox = Application.get_env(:magus, Magus.Sandbox)
    original_sprites = Application.get_env(:magus, Magus.Sandbox.Clients.Sprites)

    on_exit(fn ->
      restore(Magus.Sandbox, original_sandbox)
      restore(Magus.Sandbox.Clients.Sprites, original_sprites)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:magus, key)
  defp restore(key, value), do: Application.put_env(:magus, key, value)

  defp tool_names(conversation) do
    {tools, _} = ToolBuilder.build_tools(:chat, conversation, true, nil)
    Enum.map(tools, & &1.name())
  end

  defp build_conversation(user, attrs) do
    {:ok, conversation} = Chat.create_conversation(attrs, actor: user)
    Ash.load!(conversation, [:user], authorize?: false)
  end

  test "sandbox tools are dropped when no sandbox provider is configured" do
    # test env defaults to the :test provider, whose configured?/0 is false.
    user = generate(user())
    conversation = build_conversation(user, %{loaded_tools: ["run_code", "exec_command"]})

    names = tool_names(conversation)

    refute "run_code" in names
    refute "exec_command" in names
  end

  test "sandbox tools are offered when a sandbox provider is configured" do
    user = generate(user())
    conversation = build_conversation(user, %{loaded_tools: ["run_code", "exec_command"]})

    Application.put_env(:magus, Magus.Sandbox, provider: :sprites)
    Application.put_env(:magus, Magus.Sandbox.Clients.Sprites, api_key: "test-key")

    names = tool_names(conversation)

    assert "run_code" in names
    assert "exec_command" in names
  end
end
