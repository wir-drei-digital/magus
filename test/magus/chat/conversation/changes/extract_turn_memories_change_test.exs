defmodule Magus.Chat.Conversation.Changes.ExtractTurnMemoriesChangeTest do
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  defp seed_turn!(conv, user_text, agent_text) do
    Ash.Seed.seed!(Magus.Chat.Message, %{
      conversation_id: conv.id,
      role: :user,
      text: user_text,
      message_type: :message,
      status: :complete
    })

    Ash.Seed.seed!(Magus.Chat.Message, %{
      conversation_id: conv.id,
      role: :agent,
      text: agent_text,
      message_type: :message,
      status: :complete
    })
  end

  defp run_extract_action(conv) do
    conv
    |> Ash.Changeset.for_update(:extract_turn_memories, %{}, authorize?: false)
    |> Ash.update()
  end

  test "extraction runs inline and the action succeeds when the LLM succeeds" do
    user = generate(user())
    conv = generate(conversation(actor: user))

    seed_turn!(
      conv,
      String.duplicate("I prefer tabs over spaces in all my projects. ", 3),
      String.duplicate("Noted, I will use tabs going forward in code I write for you. ", 3)
    )

    expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
      MockResponses.generate_object_response(%{"extractions" => []})
    end)

    assert {:ok, updated} = run_extract_action(conv)
    assert is_nil(updated.extraction_due_at)
  end

  test "the action fails when the LLM fails, so Oban retries the job" do
    user = generate(user())
    conv = generate(conversation(actor: user))

    seed_turn!(
      conv,
      String.duplicate("I prefer tabs over spaces in all my projects. ", 3),
      String.duplicate("Noted, I will use tabs going forward in code I write for you. ", 3)
    )

    expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
      {:error, :llm_unavailable}
    end)

    assert {:error, _reason} = run_extract_action(conv)
  end

  alias Magus.Chat.Conversation.Changes.ExtractTurnMemories, as: Change

  describe "pair_turns/1" do
    defp msg(role, text, seconds) do
      %{
        role: role,
        text: text,
        inserted_at: DateTime.add(~U[2026-07-04 10:00:00.000000Z], seconds, :second)
      }
    end

    test "pairs each user message with the next agent message, ascending order" do
      turns =
        Change.pair_turns([
          msg(:user, "q1", 0),
          msg(:agent, "a1", 1),
          msg(:user, "q2", 2),
          msg(:agent, "a2", 3)
        ])

      assert [%{user: "q1", agent: "a1"}, %{user: "q2", agent: "a2"}] =
               Enum.map(turns, &Map.take(&1, [:user, :agent]))

      assert List.last(turns).last_inserted_at ==
               DateTime.add(~U[2026-07-04 10:00:00.000000Z], 3, :second)
    end

    test "drops a trailing user message without a response and empty-text messages" do
      turns =
        Change.pair_turns([
          msg(:agent, "stray", 0),
          msg(:user, "q1", 1),
          msg(:agent, "", 2),
          msg(:agent, "a1", 3),
          msg(:user, "pending", 4)
        ])

      assert [%{user: "q1", agent: "a1"}] = Enum.map(turns, &Map.take(&1, [:user, :agent]))
    end
  end

  describe "windowed extraction" do
    test "extracts every turn since the watermark and advances it" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      seed_turn!(
        conv,
        String.duplicate("First fact: I use Elixir daily. ", 3),
        String.duplicate("Understood, Elixir it is for everything we build. ", 3)
      )

      seed_turn!(
        conv,
        String.duplicate("Second fact: deploys go to Fly.io. ", 3),
        String.duplicate("Got it, deployments target Fly.io from now on. ", 3)
      )

      expect(LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
        assert prompt =~ "First fact"
        assert prompt =~ "Second fact"
        MockResponses.generate_object_response(%{"extractions" => []})
      end)

      assert {:ok, _} = run_extract_action(conv)

      {:ok, reloaded} = Magus.Chat.get_conversation(conv.id, authorize?: false)
      refute is_nil(reloaded.last_extracted_message_at)
    end

    test "second run only sees turns after the watermark" do
      user = generate(user())
      conv = generate(conversation(actor: user))

      seed_turn!(
        conv,
        String.duplicate("Old turn about project alpha. ", 3),
        String.duplicate("Acknowledged the alpha project details completely. ", 3)
      )

      expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
        MockResponses.generate_object_response(%{"extractions" => []})
      end)

      assert {:ok, _} = run_extract_action(conv)

      seed_turn!(
        conv,
        String.duplicate("New turn about project beta. ", 3),
        String.duplicate("Acknowledged the beta project details completely. ", 3)
      )

      expect(LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
        assert prompt =~ "beta"
        refute prompt =~ "alpha"
        MockResponses.generate_object_response(%{"extractions" => []})
      end)

      {:ok, reloaded} = Magus.Chat.get_conversation(conv.id, authorize?: false)
      assert {:ok, _} = run_extract_action(reloaded)
    end
  end
end
