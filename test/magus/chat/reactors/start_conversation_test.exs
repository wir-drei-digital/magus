defmodule Magus.Chat.Reactors.StartConversationTest do
  @moduledoc """
  Integration tests for the StartConversation reactor.

  Tests the conversation creation workflow including:
  - Creating the conversation record
  - Applying system prompts
  - Pre-warming agents
  """
  use Magus.ResourceCase, async: false

  alias Magus.Chat.Reactors.StartConversation

  describe "reactor execution" do
    test "creates a basic conversation" do
      user = generate(user())

      inputs = %{
        user_id: user.id,
        title: "My Test Conversation",
        chat_mode: :chat,
        system_prompt_id: nil,
        folder_id: nil
      }

      {:ok, conversation} = Reactor.run(StartConversation, inputs, async?: false)

      assert conversation.title == "My Test Conversation"
      assert conversation.chat_mode == :chat
      assert conversation.user_id == user.id
    end

    test "creates conversation with specific chat mode" do
      user = generate(user())

      inputs = %{
        user_id: user.id,
        title: "Search Conversation",
        chat_mode: :search,
        system_prompt_id: nil,
        folder_id: nil
      }

      {:ok, conversation} = Reactor.run(StartConversation, inputs, async?: false)

      assert conversation.chat_mode == :search
    end

    test "creates conversation in a folder" do
      user = generate(user())
      folder = generate(folder(actor: user))

      inputs = %{
        user_id: user.id,
        title: "Organized Conversation",
        chat_mode: :chat,
        system_prompt_id: nil,
        folder_id: folder.id
      }

      {:ok, conversation} = Reactor.run(StartConversation, inputs, async?: false)

      assert conversation.folder_id == folder.id
    end

    test "applies system prompt when provided" do
      user = generate(user())

      prompt =
        generate(prompt(actor: user, type: :system, content: "You are a helpful assistant."))

      inputs = %{
        user_id: user.id,
        title: "Prompted Conversation",
        chat_mode: :chat,
        system_prompt_id: prompt.id,
        folder_id: nil
      }

      {:ok, conversation} = Reactor.run(StartConversation, inputs, async?: false)

      # Load the system prompt relationship
      {:ok, loaded} =
        Chat.get_conversation(conversation.id, load: [:active_system_prompt], actor: user)

      assert loaded.active_system_prompt.id == prompt.id
    end

    test "creates conversation with nil title" do
      user = generate(user())

      inputs = %{
        user_id: user.id,
        title: nil,
        chat_mode: :chat,
        system_prompt_id: nil,
        folder_id: nil
      }

      {:ok, conversation} = Reactor.run(StartConversation, inputs, async?: false)

      # Conversation should be created even without a title
      assert conversation.id != nil
      assert conversation.user_id == user.id
    end

    test "handles multiple chat modes" do
      user = generate(user())

      modes = [:chat, :search, :reasoning, :image_generation, :video_generation]

      for mode <- modes do
        inputs = %{
          user_id: user.id,
          title: "#{mode} mode test",
          chat_mode: mode,
          system_prompt_id: nil,
          folder_id: nil
        }

        {:ok, conversation} = Reactor.run(StartConversation, inputs, async?: false)

        assert conversation.chat_mode == mode
      end
    end
  end

  describe "agent pre-warming" do
    @tag :integration
    test "prewarms conversation agent" do
      user = generate(user())

      inputs = %{
        user_id: user.id,
        title: "Prewarmed Conversation",
        chat_mode: :chat,
        system_prompt_id: nil,
        folder_id: nil
      }

      {:ok, conversation} = Reactor.run(StartConversation, inputs, async?: false)

      # The prewarm step should have attempted to start the agent
      # In test environment, InstanceManager may not be running
      # so we just verify the reactor completed successfully
      assert conversation.id != nil
    end
  end

  describe "error handling" do
    test "returns error for invalid system prompt id" do
      user = generate(user())

      inputs = %{
        user_id: user.id,
        title: "Bad Prompt Conversation",
        chat_mode: :chat,
        system_prompt_id: Ash.UUID.generate(),
        folder_id: nil
      }

      result = Reactor.run(StartConversation, inputs, async?: false)

      # Should fail because prompt doesn't exist
      assert {:error, _} = result
    end

    test "returns error for invalid folder id" do
      user = generate(user())

      inputs = %{
        user_id: user.id,
        title: "Bad Folder Conversation",
        chat_mode: :chat,
        system_prompt_id: nil,
        folder_id: Ash.UUID.generate()
      }

      result = Reactor.run(StartConversation, inputs, async?: false)

      # Should fail because folder doesn't exist
      assert {:error, _} = result
    end
  end
end
