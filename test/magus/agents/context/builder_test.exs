defmodule Magus.Agents.Context.BuilderTest do
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

  describe "wakeup preamble integration" do
    test "injects wakeup preamble when source is :heartbeat" do
      user = generate(user())
      agent = custom_agent(user, %{heartbeat_default_interval_minutes: 360})

      {:ok, conv} =
        Magus.Chat.create_conversation(%{custom_agent_id: agent.id}, actor: user)

      conv = load_conversation(conv.id, user)

      {system_prompt, _messages} =
        Builder.build_llm_context(
          conv,
          Ash.UUID.generate(),
          "(autonomous wakeup)",
          [],
          :chat,
          "openrouter:test/model",
          %{source: :heartbeat}
        )

      assert system_prompt =~ "waking up"
      assert system_prompt =~ "list_inbox_events"
    end

    test "does not inject preamble for :user_message source" do
      user = generate(user())
      agent = custom_agent(user, %{})

      {:ok, conv} =
        Magus.Chat.create_conversation(%{custom_agent_id: agent.id}, actor: user)

      conv = load_conversation(conv.id, user)

      {system_prompt, _messages} =
        Builder.build_llm_context(
          conv,
          Ash.UUID.generate(),
          "hi",
          [],
          :chat,
          "openrouter:test/model",
          %{}
        )

      refute system_prompt =~ "waking up"
      refute system_prompt =~ "list_inbox_events()"
    end

    test "injects preamble for :manual_trigger" do
      user = generate(user())
      agent = custom_agent(user, %{})

      {:ok, conv} =
        Magus.Chat.create_conversation(%{custom_agent_id: agent.id}, actor: user)

      conv = load_conversation(conv.id, user)

      {system_prompt, _messages} =
        Builder.build_llm_context(
          conv,
          Ash.UUID.generate(),
          "(manual)",
          [],
          :chat,
          "openrouter:test/model",
          %{source: :manual_trigger}
        )

      assert system_prompt =~ "manually triggered"
      assert system_prompt =~ "list_inbox_events"
    end
  end
end
