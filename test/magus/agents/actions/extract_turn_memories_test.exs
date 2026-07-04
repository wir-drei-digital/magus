defmodule Magus.Agents.Actions.ExtractTurnMemoriesTest do
  @moduledoc """
  Tests for the ExtractTurnMemories action.
  """
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.ExtractTurnMemories
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  describe "run/2" do
    test "skips extraction for very short messages" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      result =
        ExtractTurnMemories.run(
          %{
            user_id: user.id,
            conversation_id: conv.id,
            user_message: "hi",
            agent_response: "hello"
          },
          %{}
        )

      assert {:ok, %{extractions_applied: 0, extractions_skipped: 0}} = result
    end

    test "returns error for missing user_id" do
      conv = generate(conversation(actor: generate(user())))

      result =
        ExtractTurnMemories.run(
          %{
            user_id: nil,
            conversation_id: conv.id,
            user_message: "This is a longer message with enough content",
            agent_response: "This is also a substantial response with details"
          },
          %{}
        )

      assert {:error, _} = result
    end

    test "returns error for missing conversation_id" do
      user = generate(user())

      result =
        ExtractTurnMemories.run(
          %{
            user_id: user.id,
            conversation_id: nil,
            user_message: "This is a longer message with enough content",
            agent_response: "This is also a substantial response with details"
          },
          %{}
        )

      assert {:error, _} = result
    end

    test "extracts memories from conversation turn" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      # Mock the LLM response for memory extraction
      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "extractions" => [
            %{
              "name" => "Coding Style",
              "summary" => "Prefers Elixir with functional patterns, snake_case, and typespecs",
              "content" => %{
                "language" => "Elixir",
                "patterns" => "functional",
                "naming" => "snake_case",
                "typespecs" => true
              },
              "scope" => "global",
              "reason" => "User explicitly stated coding preferences"
            },
            %{
              "name" => "Current Project",
              "summary" => "Working on the Magus project",
              "content" => %{"project_name" => "Magus"},
              "scope" => "local",
              "reason" => "User mentioned current project context"
            }
          ]
        })
      end)

      # Create a conversation with enough content to trigger extraction
      user_message = """
      I'm working on the Magus project. I prefer using Elixir with functional programming patterns.
      My coding style is to use snake_case for variables and always add typespecs.
      """

      agent_response = """
      I understand you're working on Magus and prefer Elixir with functional patterns.
      I'll make sure to use snake_case naming and include typespecs in the code I write.
      """

      result =
        ExtractTurnMemories.run(
          %{
            user_id: user.id,
            conversation_id: conv.id,
            user_message: user_message,
            agent_response: agent_response
          },
          %{}
        )

      assert {:ok, %{extractions_applied: applied, extractions_skipped: skipped}} = result

      assert applied == 2
      assert skipped == 0
    end

    test "extracts from a multi-turn window" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      expect(LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
        assert prompt =~ "turn one about the Magus project"
        assert prompt =~ "turn two about preferring Elixir"

        MockResponses.generate_object_response(%{"extractions" => []})
      end)

      result =
        ExtractTurnMemories.run(
          %{
            user_id: user.id,
            conversation_id: conv.id,
            turns: [
              %{
                "user" => "This is turn one about the Magus project and its goals in detail.",
                "agent" => "Understood, the Magus project goals are noted here."
              },
              %{
                "user" => "This is turn two about preferring Elixir for everything we do.",
                "agent" => "Elixir preference recorded for future work sessions."
              }
            ]
          },
          %{}
        )

      assert {:ok, %{extractions_applied: 0}} = result
    end

    test "replace mode overwrites content instead of merging" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      {:ok, existing} =
        Magus.Memory.create_memory(
          conv.id,
          user.id,
          "Editor Preference",
          %{content: %{"editor" => "vim", "reason" => "muscle memory"}, summary: "Prefers vim"},
          actor: user
        )

      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{
          "extractions" => [
            %{
              "name" => "Editor Preference",
              "summary" => "Prefers VS Code now",
              "content" => %{"editor" => "vscode"},
              "scope" => "local",
              "update_mode" => "replace",
              "reason" => "User switched editors, superseding the old preference"
            }
          ]
        })
      end)

      assert {:ok, %{extractions_applied: 1}} =
               ExtractTurnMemories.run(
                 %{
                   user_id: user.id,
                   conversation_id: conv.id,
                   turns: [
                     %{
                       "user" =>
                         "Actually I switched to VS Code full time, forget the vim setup entirely.",
                       "agent" =>
                         "Noted, VS Code is your editor from now on, replacing the vim preference."
                     }
                   ]
                 },
                 %{}
               )

      {:ok, reloaded} = Magus.Memory.get_memory(existing.id, actor: user)
      assert reloaded.content == %{"editor" => "vscode"}
      refute Map.has_key?(reloaded.content, "reason")
    end

    test "shows more than 10 existing memory names to the extractor" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      for i <- 1..15 do
        {:ok, _} =
          Magus.Memory.create_memory(
            conv.id,
            user.id,
            "Fact #{i}",
            %{content: %{}, summary: "Summary #{i}"},
            actor: user
          )
      end

      expect(LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
        assert prompt =~ "Fact 1"
        # With the old take(10) recency cap, the oldest names fell out.
        assert Enum.all?(1..15, fn i -> prompt =~ "Fact #{i}" end)
        MockResponses.generate_object_response(%{"extractions" => []})
      end)

      assert {:ok, _} =
               ExtractTurnMemories.run(
                 %{
                   user_id: user.id,
                   conversation_id: conv.id,
                   turns: [
                     %{
                       "user" =>
                         "Here is a sufficiently long user message about ongoing project work.",
                       "agent" =>
                         "Here is a sufficiently long agent response acknowledging the project work."
                     }
                   ]
                 },
                 %{}
               )
    end
  end

  describe "schema validation" do
    test "has correct schema definition" do
      schema = ExtractTurnMemories.schema()

      assert Keyword.has_key?(schema, :user_id)
      assert Keyword.has_key?(schema, :conversation_id)
      assert Keyword.has_key?(schema, :user_message)
      assert Keyword.has_key?(schema, :agent_response)
    end
  end
end
