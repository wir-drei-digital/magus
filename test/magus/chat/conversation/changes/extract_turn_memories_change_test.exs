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
end
