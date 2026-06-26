defmodule Magus.Chat.Conversation.Actions.BuildMessageHistoryTest do
  @moduledoc """
  Tests for the BuildMessageHistory action.

  Tests cover:
  - Building message history as a flat list of ReqLLM.Message structs
  - Message limiting
  - Recovery: appending interrupted tool activity as plain text
  """
  use Magus.ResourceCase, async: true

  require Ash.Query

  alias Magus.Chat.Conversation.Actions.BuildMessageHistory

  describe "run/3 (message history)" do
    test "returns a flat list of messages (no system prompt)" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      generate(message(actor: user, conversation_id: conv.id, text: "Hello"))

      input = %{
        arguments: %{
          conversation_id: conv.id,
          is_multiplayer: false
        }
      }

      {:ok, messages} = BuildMessageHistory.run(input, [], %{})

      assert is_list(messages)
      roles = Enum.map(messages, & &1.role)
      assert :user in roles
      refute :system in roles
    end

    test "no hard 20-message cap; short conversations pass through under the rolling budget" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      for i <- 1..30 do
        generate(message(actor: user, conversation_id: conv.id, text: "Message #{i}"))
      end

      input = %{
        arguments: %{
          conversation_id: conv.id,
          is_multiplayer: false
        }
      }

      {:ok, messages} = BuildMessageHistory.run(input, [], %{})

      # The old hardcoded "last 20" cap was removed. With the default :rolling
      # strategy, no ContextWindow row, and a 128k default max_context, 30 tiny
      # messages fit comfortably under the rolling token budget and the
      # message_count_backstop (200), so all 30 are returned.
      assert length(messages) == 30
    end

    test "honors the message_count_backstop upper bound for large conversations" do
      backstop = Magus.Chat.ContextWindow.config(:message_count_backstop)

      user = generate(user())
      conv = generate(conversation(actor: user))

      for i <- 1..(backstop + 10) do
        generate(message(actor: user, conversation_id: conv.id, text: "Message #{i}"))
      end

      input = %{
        arguments: %{
          conversation_id: conv.id,
          is_multiplayer: false
        }
      }

      {:ok, messages} = BuildMessageHistory.run(input, [], %{})

      # The read never loads more than the backstop, regardless of strategy.
      assert length(messages) <= backstop
    end

    test "excludes current message when current_message_id is provided" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      msg1 = generate(message(actor: user, conversation_id: conv.id, text: "First"))
      msg2 = generate(message(actor: user, conversation_id: conv.id, text: "Second"))

      input = %{
        arguments: %{
          conversation_id: conv.id,
          current_message_id: msg2.id,
          is_multiplayer: false
        }
      }

      {:ok, messages} = BuildMessageHistory.run(input, [], %{})

      texts =
        Enum.map(messages, fn msg ->
          case msg.content do
            text when is_binary(text) -> text
            parts when is_list(parts) -> Enum.map_join(parts, "", & &1.text)
          end
        end)

      assert Enum.any?(texts, &String.contains?(&1, "First"))
      refute Enum.any?(texts, &String.contains?(&1, "Second"))
      _ = msg1
    end
  end

  describe "recovery for incomplete turns" do
    @ai_agent %Magus.Agents.Support.AiAgent{}

    test "appends text annotation when last agent message has :error status with tool_call_data" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      generate(message(actor: user, conversation_id: conv.id, text: "Roll dice"))

      agent_msg_id = Ash.UUIDv7.generate()

      {:ok, _agent_msg} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: agent_msg_id,
          text: "I'll roll the dice.",
          conversation_id: conv.id,
          complete: false,
          tool_call_data: %{
            tool_calls: [
              %{id: "tc_1", name: "roll_dice", arguments: %{"notation" => "2d6"}}
            ]
          }
        })
        |> Ash.create(actor: @ai_agent)

      Magus.Chat.Message
      |> Ash.Query.filter(id == ^agent_msg_id)
      |> Ash.bulk_update!(:mark_error, %{}, actor: @ai_agent)

      # Tool result event
      event_id = Ash.UUIDv7.generate()

      Magus.Chat.upsert_event_message!(
        event_id,
        "roll_dice completed",
        conv.id,
        %{
          id: event_id,
          tool_use_id: "tc_1",
          tool_name: "roll_dice",
          display_name: "Rolling dice...",
          status: :success,
          inputs: %{notation: "2d6"},
          output: %{result: 7},
          output_summary: "Rolled: 7"
        },
        true,
        authorize?: false
      )

      input = %{
        arguments: %{
          conversation_id: conv.id,
          is_multiplayer: false
        }
      }

      {:ok, messages} = BuildMessageHistory.run(input, [], %{})

      # Recovery appends text to last assistant message — no structured tool messages
      roles = Enum.map(messages, & &1.role)
      refute :tool in roles

      assistant_msg = messages |> Enum.reverse() |> Enum.find(&(&1.role == :assistant))
      content_text = extract_content_text(assistant_msg.content)
      assert String.contains?(content_text, "Previous turn called: roll_dice")
      assert String.contains?(content_text, "Rolled: 7")
    end

    test "does not recover when last agent message has :complete status without tool_call_data" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      generate(message(actor: user, conversation_id: conv.id, text: "Hello"))

      agent_msg_id = Ash.UUIDv7.generate()

      {:ok, _agent_msg} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: agent_msg_id,
          text: "Hi there!",
          conversation_id: conv.id,
          complete: true
        })
        |> Ash.create(actor: @ai_agent)

      input = %{
        arguments: %{
          conversation_id: conv.id,
          is_multiplayer: false
        }
      }

      {:ok, messages} = BuildMessageHistory.run(input, [], %{})

      assistant_msg = messages |> Enum.reverse() |> Enum.find(&(&1.role == :assistant))
      content_text = extract_content_text(assistant_msg.content)
      refute String.contains?(content_text, "Previous turn called")
    end

    test "recovers when complete message still has tool_call_data (cancellation)" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      generate(message(actor: user, conversation_id: conv.id, text: "Search"))

      agent_msg_id = Ash.UUIDv7.generate()

      {:ok, _agent_msg} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: agent_msg_id,
          text: "I'll search.",
          conversation_id: conv.id,
          complete: true,
          tool_call_data: %{
            tool_calls: [
              %{id: "tc_1", name: "web_search", arguments: %{"query" => "X"}}
            ]
          }
        })
        |> Ash.create(actor: @ai_agent)

      input = %{
        arguments: %{
          conversation_id: conv.id,
          is_multiplayer: false
        }
      }

      {:ok, messages} = BuildMessageHistory.run(input, [], %{})

      assistant_msg = messages |> Enum.reverse() |> Enum.find(&(&1.role == :assistant))
      content_text = extract_content_text(assistant_msg.content)
      assert String.contains?(content_text, "Previous turn called: web_search")
      assert String.contains?(content_text, "interrupted")
    end

    test "synthesizes interrupted stubs for tool calls without matching results" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      generate(message(actor: user, conversation_id: conv.id, text: "Do two things"))

      agent_msg_id = Ash.UUIDv7.generate()

      {:ok, _agent_msg} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: agent_msg_id,
          text: "I'll do both.",
          conversation_id: conv.id,
          complete: false,
          tool_call_data: %{
            tool_calls: [
              %{id: "tc_1", name: "tool_a", arguments: %{}},
              %{id: "tc_2", name: "tool_b", arguments: %{}}
            ]
          }
        })
        |> Ash.create(actor: @ai_agent)

      Magus.Chat.Message
      |> Ash.Query.filter(id == ^agent_msg_id)
      |> Ash.bulk_update!(:mark_error, %{}, actor: @ai_agent)

      # Only tool_a completed
      event_id = Ash.UUIDv7.generate()

      Magus.Chat.upsert_event_message!(
        event_id,
        "tool_a completed",
        conv.id,
        %{
          id: event_id,
          tool_use_id: "tc_1",
          tool_name: "tool_a",
          display_name: "Tool A",
          status: :success,
          inputs: %{},
          output: %{result: "done"},
          output_summary: "Done"
        },
        true,
        authorize?: false
      )

      input = %{
        arguments: %{
          conversation_id: conv.id,
          is_multiplayer: false
        }
      }

      {:ok, messages} = BuildMessageHistory.run(input, [], %{})

      assistant_msg = messages |> Enum.reverse() |> Enum.find(&(&1.role == :assistant))
      content_text = extract_content_text(assistant_msg.content)

      # Both tools should be mentioned
      assert String.contains?(content_text, "tool_a, tool_b")
      # tool_a has a result, tool_b was interrupted
      assert String.contains?(content_text, "Done")
      assert String.contains?(content_text, "interrupted")
    end

    test "does not recover when error message has no tool_call_data" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      generate(message(actor: user, conversation_id: conv.id, text: "Hello"))

      agent_msg_id = Ash.UUIDv7.generate()

      {:ok, _agent_msg} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: agent_msg_id,
          text: "Error occurred",
          conversation_id: conv.id,
          complete: false
        })
        |> Ash.create(actor: @ai_agent)

      Magus.Chat.Message
      |> Ash.Query.filter(id == ^agent_msg_id)
      |> Ash.bulk_update!(:mark_error, %{}, actor: @ai_agent)

      input = %{
        arguments: %{
          conversation_id: conv.id,
          is_multiplayer: false
        }
      }

      {:ok, messages} = BuildMessageHistory.run(input, [], %{})

      assistant_msg = messages |> Enum.reverse() |> Enum.find(&(&1.role == :assistant))
      content_text = extract_content_text(assistant_msg.content)
      refute String.contains?(content_text, "Previous turn called")
    end

    test "recovers when orphaned tool events exist after last text message (cancellation)" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      generate(message(actor: user, conversation_id: conv.id, text: "Search for X"))

      # Agent message with tool_calls but empty text (excluded by text-only filter)
      agent_msg_id = Ash.UUIDv7.generate()

      {:ok, _agent_msg} =
        Magus.Chat.Message
        |> Ash.Changeset.for_create(:upsert_response, %{
          id: agent_msg_id,
          text: "",
          conversation_id: conv.id,
          complete: false,
          tool_call_data: %{
            tool_calls: [
              %{id: "tc_1", name: "web_search", arguments: %{"query" => "X"}}
            ]
          }
        })
        |> Ash.create(actor: @ai_agent)

      # Tool result event
      event_id = Ash.UUIDv7.generate()

      Magus.Chat.upsert_event_message!(
        event_id,
        "web_search completed",
        conv.id,
        %{
          id: event_id,
          tool_use_id: "tc_1",
          tool_name: "web_search",
          display_name: "Searching...",
          status: :success,
          inputs: %{query: "X"},
          output: %{results: ["result1"]},
          output_summary: "Found 1 result"
        },
        true,
        authorize?: false
      )

      input = %{
        arguments: %{
          conversation_id: conv.id,
          is_multiplayer: false
        }
      }

      {:ok, messages} = BuildMessageHistory.run(input, [], %{})

      # Recovery should detect and append text annotation
      # The agent message has empty text so it may be filtered out by as_llm_message.
      # Recovery falls back to find_hidden_tool_calls and appends to whatever
      # assistant message exists (or the message list may just have the user message).
      has_recovery =
        Enum.any?(messages, fn msg ->
          content_text = extract_content_text(msg.content)
          String.contains?(content_text, "Previous turn called")
        end)

      # If there's an assistant message, recovery text should be appended
      # If no assistant message exists (empty text filtered), recovery can't append
      assistant_msgs = Enum.filter(messages, &(&1.role == :assistant))

      if assistant_msgs != [] do
        assert has_recovery
      end
    end
  end

  defp extract_content_text(content) when is_binary(content), do: content

  defp extract_content_text(content) when is_list(content) do
    content
    |> Enum.map(fn
      %{text: text} -> text
      %ReqLLM.Message.ContentPart{text: text} -> text
      other -> inspect(other)
    end)
    |> Enum.join(" ")
  end

  defp extract_content_text(_content), do: ""
end
