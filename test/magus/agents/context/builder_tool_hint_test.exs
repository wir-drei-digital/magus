defmodule Magus.Agents.Context.BuilderToolHintTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Context.Builder

  defp load_conversation(id, user) do
    Magus.Chat.get_conversation!(id,
      load: [
        :workspace,
        active_system_prompt: [:model],
        members: [:user],
        custom_agent: [:model, :image_model, :video_model],
        user: [:selected_model, :selected_image_model, :selected_video_model]
      ],
      actor: user
    )
  end

  defp build(conv, text) do
    {system_prompt, _messages} =
      Builder.build_llm_context(
        conv,
        Ash.UUID.generate(),
        text,
        [],
        :chat,
        "openrouter:test/model",
        %{}
      )

    system_prompt
  end

  test "injects a tool_search hint when the message matches a hidden tool" do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{}, actor: user)
    conv = load_conversation(conv.id, user)

    system_prompt = build(conv, "can you roll a dice for me")
    assert system_prompt =~ "may be available via tool_search"
    assert system_prompt =~ "roll_dice"
  end

  test "does not inject a hint for an unrelated message" do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{}, actor: user)
    conv = load_conversation(conv.id, user)

    system_prompt = build(conv, "photosynthesis chlorophyll metabolism")
    refute system_prompt =~ "may be available via tool_search"
  end
end
