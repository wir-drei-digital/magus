defmodule Magus.Agents.Tools.ToolBuilderLoadedToolsTest do
  use Magus.ResourceCase, async: true

  import Magus.Generators

  alias Magus.Agents.Tools.ToolBuilder
  alias Magus.Chat

  defp tool_names(conversation, mode \\ :chat) do
    {tools, _} = ToolBuilder.build_tools(mode, conversation, true, nil)
    Enum.map(tools, & &1.name())
  end

  defp build_conversation(user, attrs \\ %{}) do
    {:ok, conversation} = Chat.create_conversation(attrs, actor: user)
    Ash.load!(conversation, [:user], authorize?: false)
  end

  test "search and load tools are always in the base set" do
    user = generate(user())
    names = tool_names(build_conversation(user))
    assert "tool_search" in names
    assert "load_tool" in names
  end

  test "de-noised tools are not in the base set in chat mode" do
    user = generate(user())
    names = tool_names(build_conversation(user))
    refute "roll_dice" in names
    refute "list_models" in names
    refute "generate_image" in names
    refute "create_thread" in names
  end

  test "tools listed in loaded_tools are added back" do
    user = generate(user())
    conversation = build_conversation(user, %{loaded_tools: ["roll_dice", "list_models"]})
    names = tool_names(conversation)
    assert "roll_dice" in names
    assert "list_models" in names
  end

  test "generate_image is available in image_generation mode" do
    user = generate(user())
    names = tool_names(build_conversation(user), :image_generation)
    assert "generate_image" in names
  end

  test "generate_video is available in video_generation mode" do
    user = generate(user())
    names = tool_names(build_conversation(user), :video_generation)
    assert "generate_video" in names
  end
end
