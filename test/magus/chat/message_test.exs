defmodule Magus.Chat.MessageTest do
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Chat

  require Ash.Query

  # AI agent actor for system/agent operations
  @ai_agent %Magus.Agents.Support.AiAgent{}

  describe "create/1" do
    test "creates message with valid attributes" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(
          %{
            text: "Hello, world!",
            conversation_id: conversation.id
          },
          actor: user
        )

      assert message.text == "Hello, world!"
      assert message.conversation_id == conversation.id
      assert message.role == :user
      assert message.source == :user
      assert message.created_by_id == user.id
    end

    test "creates message with specific mode" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(
          %{
            text: "Search for this",
            conversation_id: conversation.id,
            mode: :search
          },
          actor: user
        )

      assert message.mode == :search
    end

    test "creates conversation if not provided" do
      user = generate(user())

      {:ok, message} =
        Chat.create_message(
          %{
            text: "Auto-create conversation"
          },
          actor: user
        )

      assert message.conversation_id != nil
    end

    test "create action does not trigger agent (use send_user_message instead)" do
      # Note: The :create action is a raw create that doesn't trigger the agent.
      # Use :send_user_message to trigger the Jido conversation agent.
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(
          %{
            text: "Hello",
            conversation_id: conversation.id
          },
          actor: user
        )

      # Message is created but no Oban job is enqueued (Jido agents handle responses now)
      assert message.text == "Hello"
      assert message.role == :user
    end

    test "observer cannot send messages in multiplayer conversation" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, conversation} = Chat.enable_multiplayer(conversation, actor: owner)

      observer_user = generate(user())

      {:ok, member} =
        Chat.add_conversation_member(
          conversation.id,
          observer_user.id,
          %{role: :observer},
          authorize?: false
        )

      {:ok, _} = Chat.accept_conversation_invitation(member, actor: observer_user)

      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.create_message(
                 %{
                   text: "hello",
                   conversation_id: conversation.id
                 },
                 actor: observer_user
               )
    end

    test "member can send messages in multiplayer conversation" do
      owner = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: owner)
      {:ok, conversation} = Chat.enable_multiplayer(conversation, actor: owner)

      member_user = generate(user())

      {:ok, member} =
        Chat.add_conversation_member(
          conversation.id,
          member_user.id,
          %{role: :member},
          authorize?: false
        )

      {:ok, _} = Chat.accept_conversation_invitation(member, actor: member_user)

      assert {:ok, _message} =
               Chat.create_message(
                 %{
                   text: "hello",
                   conversation_id: conversation.id
                 },
                 actor: member_user
               )
    end
  end

  describe "send_user_message/1" do
    test "attaches resources to message" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      resource_id = Ash.UUIDv7.generate()

      {:ok, message} =
        Chat.send_user_message(
          %{
            text: "Check this file",
            conversation_id: conversation.id,
            resources: [%{"id" => resource_id, "type" => "image"}]
          },
          actor: user
        )

      # Resources should be stored in metadata
      assert message.metadata != nil
    end

    test "defaults mode from the conversation's chat_mode when the client omits it" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{chat_mode: :image_generation}, actor: user)

      {:ok, message} =
        Chat.send_user_message(
          %{text: "a cat in a hat", conversation_id: conversation.id},
          actor: user
        )

      assert message.mode == :image_generation
    end

    test "explicit mode wins over the conversation's chat_mode" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{chat_mode: :image_generation}, actor: user)

      {:ok, message} =
        Chat.send_user_message(
          %{text: "just chatting", conversation_id: conversation.id, mode: :chat},
          actor: user
        )

      assert message.mode == :chat
    end

    test "enqueue_message also defaults mode from the conversation's chat_mode" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{chat_mode: :video_generation}, actor: user)

      {:ok, message} =
        Chat.enqueue_message(conversation.id, %{text: "a rocket launch"}, actor: user)

      assert message.mode == :video_generation
    end
  end

  describe "for_conversation/1" do
    test "returns messages for conversation in descending order" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, msg1} =
        Chat.create_message(%{text: "First", conversation_id: conversation.id}, actor: user)

      {:ok, msg2} =
        Chat.create_message(%{text: "Second", conversation_id: conversation.id}, actor: user)

      {:ok, messages} = Chat.message_history(conversation.id, actor: user)

      # Most recent first
      assert hd(messages).id == msg2.id
      assert List.last(messages).id == msg1.id
    end
  end

  describe "for_llm_context/1" do
    test "excludes disabled messages" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, msg1} =
        Chat.create_message(%{text: "Keep this", conversation_id: conversation.id}, actor: user)

      {:ok, msg2} =
        Chat.create_message(%{text: "Disable this", conversation_id: conversation.id},
          actor: user
        )

      {:ok, _disabled} = Chat.toggle_message_disabled(msg2, actor: user)

      {:ok, messages} =
        Chat.list_messages_for_llm_context(conversation.id, nil, nil, actor: user)

      message_ids = Enum.map(messages, & &1.id)
      assert msg1.id in message_ids
      refute msg2.id in message_ids
    end

    test "returns messages in ascending order" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, msg1} =
        Chat.create_message(%{text: "First", conversation_id: conversation.id}, actor: user)

      Process.sleep(10)

      {:ok, msg2} =
        Chat.create_message(%{text: "Second", conversation_id: conversation.id}, actor: user)

      {:ok, messages} =
        Chat.list_messages_for_llm_context(conversation.id, nil, nil, actor: user)

      # Oldest first for LLM context
      assert hd(messages).id == msg1.id
      assert List.last(messages).id == msg2.id
    end

    test "since_at excludes messages before the timestamp" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, m1} =
        Chat.create_message(%{text: "First", conversation_id: conversation.id}, actor: user)

      Process.sleep(10)

      {:ok, m2} =
        Chat.create_message(%{text: "Second", conversation_id: conversation.id}, actor: user)

      Process.sleep(10)

      {:ok, m3} =
        Chat.create_message(%{text: "Third", conversation_id: conversation.id}, actor: user)

      results =
        Magus.Chat.Message
        |> Ash.Query.for_read(:for_llm_context, %{
          conversation_id: conversation.id,
          since_at: m2.inserted_at
        })
        |> Ash.read!(actor: @ai_agent)

      ids = Enum.map(results, & &1.id)

      refute m1.id in ids
      assert m2.id in ids
      assert m3.id in ids
    end
  end

  describe "toggle_disabled/1" do
    test "toggles disabled state" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(%{text: "Test", conversation_id: conversation.id}, actor: user)

      assert message.disabled == false

      {:ok, disabled} = Chat.toggle_message_disabled(message, actor: user)
      assert disabled.disabled == true

      {:ok, enabled} = Chat.toggle_message_disabled(disabled, actor: user)
      assert enabled.disabled == false
    end
  end

  describe "upsert_response/1" do
    test "creates agent response message" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, user_msg} =
        Chat.create_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      response_id = Ash.UUIDv7.generate()

      {:ok, response} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: response_id,
          text: "Hi there!",
          conversation_id: conversation.id,
          response_to_id: user_msg.id,
          complete: true
        })
        |> Ash.create(actor: @ai_agent)

      assert response.id == response_id
      assert response.text == "Hi there!"
      assert response.role == :agent
      assert response.source == :agent
      assert response.complete == true
    end

    test "updates existing response on upsert" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, user_msg} =
        Chat.create_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      response_id = Ash.UUIDv7.generate()

      # Create initial response
      {:ok, _} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: response_id,
          text: "Partial...",
          conversation_id: conversation.id,
          response_to_id: user_msg.id,
          complete: false
        })
        |> Ash.create(actor: @ai_agent)

      # Update with complete response
      {:ok, updated} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: response_id,
          text: "Complete response!",
          conversation_id: conversation.id,
          response_to_id: user_msg.id,
          complete: true
        })
        |> Ash.create(actor: @ai_agent)

      assert updated.text == "Complete response!"
      assert updated.complete == true
    end
  end

  describe "create_event/1" do
    test "creates event message" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, event} =
        Chat.create_event_message("Tool called: search", conversation.id, actor: @ai_agent)

      assert event.text == "Tool called: search"
      assert event.message_type == :event
      assert event.source == :agent
      assert event.complete == true
    end
  end

  describe "upsert_event/1" do
    test "creates event message with tool_call_data" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      event_id = Ash.UUIDv7.generate()

      tool_call_data = %{
        id: event_id,
        status: :success,
        tool_name: "roll_dice",
        display_name: "Rolling dice...",
        inputs: %{sides: 6},
        output: %{result: 4},
        output_summary: "Rolled: 4",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        duration_ms: 15,
        error: nil
      }

      event =
        Chat.upsert_event_message!(
          event_id,
          "Rolling dice... - Rolled: 4",
          conversation.id,
          tool_call_data,
          true,
          authorize?: false
        )

      assert event.id == event_id
      assert event.text == "Rolling dice... - Rolled: 4"
      assert event.message_type == :event
      assert event.source == :agent
      assert event.complete == true
      assert event.tool_call_data != nil
      # Keys become strings when stored in PostgreSQL
      assert event.tool_call_data["tool_name"] == "roll_dice"
      assert event.tool_call_data["status"] == "success"
      assert event.tool_call_data["output_summary"] == "Rolled: 4"
    end

    test "creates in-progress event and updates on completion" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      event_id = Ash.UUIDv7.generate()
      started_at = DateTime.utc_now()

      # Create in-progress event
      in_progress_data = %{
        id: event_id,
        status: :in_progress,
        tool_name: "web_search",
        display_name: "Searching the web...",
        inputs: %{query: "elixir phoenix"},
        output: nil,
        output_summary: nil,
        started_at: started_at,
        completed_at: nil,
        duration_ms: nil,
        error: nil
      }

      in_progress_event =
        Chat.upsert_event_message!(
          event_id,
          "Searching the web...",
          conversation.id,
          in_progress_data,
          false,
          authorize?: false
        )

      assert in_progress_event.complete == false
      # Keys become strings when stored in PostgreSQL
      assert in_progress_event.tool_call_data["status"] == "in_progress"

      # Update with completed event
      completed_at = DateTime.utc_now()

      completed_data = %{
        id: event_id,
        status: :success,
        tool_name: "web_search",
        display_name: "Searching the web...",
        inputs: %{query: "elixir phoenix"},
        output: %{results: ["result1", "result2"]},
        output_summary: "Found 2 results",
        started_at: started_at,
        completed_at: completed_at,
        duration_ms: 250,
        error: nil
      }

      completed_event =
        Chat.upsert_event_message!(
          event_id,
          "Searching the web... - Found 2 results",
          conversation.id,
          completed_data,
          true,
          authorize?: false
        )

      # Should be the same record, updated
      assert completed_event.id == event_id
      assert completed_event.complete == true
      assert completed_event.text == "Searching the web... - Found 2 results"
      assert completed_event.tool_call_data["status"] == "success"
      assert completed_event.tool_call_data["output_summary"] == "Found 2 results"
      assert completed_event.tool_call_data["duration_ms"] == 250
    end

    test "creates error event" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      event_id = Ash.UUIDv7.generate()

      error_data = %{
        id: event_id,
        status: :error,
        tool_name: "create_note",
        display_name: "Creating note...",
        inputs: %{title: "Test Note"},
        output: nil,
        output_summary: "Error",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        duration_ms: 5,
        error: "Permission denied"
      }

      error_event =
        Chat.upsert_event_message!(
          event_id,
          "Creating note... - Error",
          conversation.id,
          error_data,
          true,
          authorize?: false
        )

      # Keys become strings when stored in PostgreSQL
      assert error_event.tool_call_data["status"] == "error"
      assert error_event.tool_call_data["error"] == "Permission denied"
    end
  end

  describe "for_llm_context with tool events" do
    test "excludes tool events from context history (handled by recovery in BuildMessageHistory)" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, user_msg} =
        Chat.create_message(%{text: "Roll a dice", conversation_id: conversation.id}, actor: user)

      event_id = Ash.UUIDv7.generate()

      tool_call_data = %{
        id: event_id,
        status: :success,
        tool_name: "roll_dice",
        display_name: "Rolling dice...",
        inputs: %{sides: 6},
        output: %{result: 4},
        output_summary: "Rolled: 4",
        started_at: DateTime.utc_now(),
        completed_at: DateTime.utc_now(),
        duration_ms: 10,
        error: nil
      }

      _tool_event =
        Chat.upsert_event_message!(
          event_id,
          "Rolling dice... - Rolled: 4",
          conversation.id,
          tool_call_data,
          true,
          authorize?: false
        )

      {:ok, messages} =
        Chat.list_messages_for_llm_context(conversation.id, nil, nil, actor: user)

      message_ids = Enum.map(messages, & &1.id)

      # Tool events are excluded from the base query — recovery is handled
      # separately in BuildMessageHistory for incomplete turns.
      assert user_msg.id in message_ids
      refute event_id in message_ids
    end

    test "excludes legacy events without tool_call_data" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Create a regular user message
      {:ok, user_msg} =
        Chat.create_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      # Create a legacy event (no tool_call_data)
      legacy_event =
        Chat.create_event_message!("Some legacy event", conversation.id, actor: @ai_agent)

      {:ok, messages} =
        Chat.list_messages_for_llm_context(conversation.id, nil, nil, actor: user)

      message_ids = Enum.map(messages, & &1.id)

      # User message should be included, legacy event should not
      assert user_msg.id in message_ids
      refute legacy_event.id in message_ids
    end
  end

  describe "for_llm_context with empty messages" do
    test "excludes messages with empty text and no tool_call_data" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Create a regular user message
      {:ok, user_msg} =
        Chat.create_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      # Create an agent response with empty text (simulating tool-only response)
      empty_response_id = Ash.UUIDv7.generate()

      {:ok, _empty_response} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: empty_response_id,
          text: "",
          conversation_id: conversation.id,
          response_to_id: user_msg.id,
          complete: true
        })
        |> Ash.create(actor: @ai_agent)

      {:ok, messages} =
        Chat.list_messages_for_llm_context(conversation.id, nil, nil, actor: user)

      message_ids = Enum.map(messages, & &1.id)

      # User message should be included, empty response should be excluded
      assert user_msg.id in message_ids
      refute empty_response_id in message_ids
    end

    test "excludes tool-only assistant messages with empty text even when tool_call_data exists" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, user_msg} =
        Chat.create_message(%{text: "Use a tool", conversation_id: conversation.id}, actor: user)

      response_id = Ash.UUIDv7.generate()

      {:ok, _response} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: response_id,
          text: "",
          conversation_id: conversation.id,
          response_to_id: user_msg.id,
          complete: true,
          tool_call_data: %{
            tool_calls: [
              %{
                id: "tool_call_1",
                name: "roll_dice",
                arguments: %{"notation" => "2d10"}
              }
            ]
          }
        })
        |> Ash.create(actor: @ai_agent)

      {:ok, messages} =
        Chat.list_messages_for_llm_context(conversation.id, nil, nil, actor: user)

      message_ids = Enum.map(messages, & &1.id)

      # Tool-only assistant messages (empty text) are excluded from the base
      # query. Recovery for incomplete turns is handled in BuildMessageHistory.
      assert user_msg.id in message_ids
      refute response_id in message_ids
    end

    test "includes messages with non-empty text" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Create user message
      {:ok, user_msg} =
        Chat.create_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      # Create agent response with text
      response_id = Ash.UUIDv7.generate()

      {:ok, _response} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: response_id,
          text: "Hi there!",
          conversation_id: conversation.id,
          response_to_id: user_msg.id,
          complete: true
        })
        |> Ash.create(actor: @ai_agent)

      {:ok, messages} =
        Chat.list_messages_for_llm_context(conversation.id, nil, nil, actor: user)

      message_ids = Enum.map(messages, & &1.id)

      # Both messages should be included
      assert user_msg.id in message_ids
      assert response_id in message_ids
    end
  end

  describe "mark_stopped/1" do
    test "marks message as complete" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(%{text: "Test", conversation_id: conversation.id}, actor: user)

      {:ok, stopped} = Chat.mark_message_stopped(message, actor: user)

      assert stopped.complete == true
      assert stopped.status == :complete
    end
  end

  describe "error-reason recording" do
    test "mark_error records the provided error reason" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(%{text: "Test", conversation_id: conversation.id}, actor: user)

      {:ok, errored} =
        Chat.mark_message_error(
          message,
          %{error: %{"reason" => "request_failed", "detail" => "boom"}},
          authorize?: false
        )

      assert errored.status == :error
      assert errored.complete == true
      assert errored.error["reason"] == "request_failed"
      assert errored.error["detail"] == "boom"
    end

    test "mark_error without a reason stays backward compatible (error nil)" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(%{text: "Test", conversation_id: conversation.id}, actor: user)

      {:ok, errored} = Chat.mark_message_error(message, %{}, authorize?: false)

      assert errored.status == :error
      assert errored.error == nil
    end

    test "cleanup_stale_streaming records a stale_streaming_timeout reason" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(%{text: "partial", conversation_id: conversation.id}, actor: user)

      {:ok, swept} =
        message
        |> Ash.Changeset.for_update(:cleanup_stale_streaming, %{})
        |> Ash.update(authorize?: false)

      assert swept.status == :error
      assert swept.complete == true
      assert swept.error["reason"] == "stale_streaming_timeout"
    end
  end

  describe "calculations" do
    test "needs_response is true for user messages without response" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, message} =
        Chat.create_message(%{text: "Hello", conversation_id: conversation.id}, actor: user)

      {:ok, loaded} = Ash.load(message, :needs_response, actor: @ai_agent)

      assert loaded.needs_response == true
    end
  end

  describe "workspace conversation access" do
    setup do
      owner = generate(user())
      member = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{
            name: "Msg Access",
            slug: "msg-access-#{System.unique_integer([:positive])}"
          },
          actor: owner
        )

      {:ok, invite} =
        Magus.Workspaces.invite_member(workspace.id, member.email, actor: owner)

      {:ok, _} = Magus.Workspaces.accept_invite(invite.invite_token, actor: member)

      {:ok, shared} =
        Chat.create_conversation(%{workspace_id: workspace.id}, actor: owner)

      {:ok, shared} = Chat.share_conversation_to_team(shared, actor: owner)

      {:ok, owner_message} =
        Chat.create_message(
          %{text: "from owner", conversation_id: shared.id},
          actor: owner
        )

      {:ok, private} =
        Chat.create_conversation(%{workspace_id: workspace.id}, actor: owner)

      {:ok, _private_message} =
        Chat.create_message(
          %{text: "private", conversation_id: private.id},
          actor: owner
        )

      %{
        owner: owner,
        member: member,
        shared: shared,
        owner_message: owner_message,
        private: private
      }
    end

    test "workspace member can read messages in shared conversation",
         %{member: member, shared: shared, owner_message: owner_message} do
      messages =
        Magus.Chat.Message
        |> Ash.Query.filter(conversation_id == ^shared.id)
        |> Ash.read!(actor: member)

      assert Enum.any?(messages, &(&1.id == owner_message.id))
    end

    test "workspace member cannot read messages in private workspace conversation",
         %{member: member, private: private} do
      messages =
        Magus.Chat.Message
        |> Ash.Query.filter(conversation_id == ^private.id)
        |> Ash.read!(actor: member)

      assert messages == []
    end

    test "workspace member can post a message in shared conversation",
         %{member: member, shared: shared} do
      assert {:ok, message} =
               Chat.create_message(
                 %{text: "hello from member", conversation_id: shared.id},
                 actor: member
               )

      assert message.created_by_id == member.id
      assert message.conversation_id == shared.id
    end

    test "workspace member cannot post a message in private workspace conversation",
         %{member: member, private: private} do
      assert {:error, %Ash.Error.Forbidden{}} =
               Chat.create_message(
                 %{text: "should fail", conversation_id: private.id},
                 actor: member
               )
    end
  end

  describe "create_draft_event" do
    # Regression: the export_format constraint once omitted :markdown while the
    # Draft :export action offered it, so markdown exports failed with a raw
    # "atom must be one of %{atom_list}" constraint error.
    test "accepts every draft export format, including markdown" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      for format <- [:pdf, :docx, :latex, :markdown] do
        assert {:ok, message} =
                 Chat.create_draft_event_message(
                   "Export the draft",
                   conversation.id,
                   :export,
                   Ash.UUID.generate(),
                   %{export_format: format},
                   actor: user
                 )

        assert message.message_type == :draft_event
        assert message.metadata["export_format"] == to_string(format)
      end
    end
  end
end
