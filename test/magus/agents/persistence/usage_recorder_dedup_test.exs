defmodule Magus.Agents.Persistence.UsageRecorderDedupTest do
  use Magus.DataCase, async: false

  import Magus.Generators
  require Ash.Query

  alias Magus.Agents.Persistence.UsageRecorder

  # Usage idempotency (magus-z6yx): message ids are deterministic per
  # (request, iteration), so a recovery re-run replays the same identity.
  # The recorder must keep the original row (whose id the meter dedupes on)
  # and drop the replay instead of inserting a fresh row id.

  setup do
    user = generate(user())
    model = generate(model())
    conversation = generate(conversation(actor: user))
    message = generate(message(actor: user, conversation_id: conversation.id, text: "hi"))

    %{user: user, model: model, conversation: conversation, message: message}
  end

  defp record(ctx, overrides) do
    defaults = [
      user_id: ctx.user.id,
      message_id: ctx.message.id,
      conversation_id: ctx.conversation.id,
      model: ctx.model,
      usage: %{"prompt_tokens" => 10, "completion_tokens" => 5},
      usage_type: :response
    ]

    UsageRecorder.record(Keyword.merge(defaults, overrides))
  end

  defp rows_for(message_id) do
    Magus.Usage.MessageUsage
    |> Ash.Query.filter(message_id == ^message_id)
    |> Ash.read!(authorize?: false)
  end

  test "replaying the same (message, usage_type, action_name) records once", ctx do
    assert {:ok, %{id: original_id}} = record(ctx, [])
    assert {:ok, :duplicate} = record(ctx, [])

    assert [%{id: ^original_id}] = rows_for(ctx.message.id)
  end

  test "the original row and its figures survive a replay with different numbers", ctx do
    assert {:ok, %{id: original_id}} = record(ctx, [])

    assert {:ok, :duplicate} =
             record(ctx, usage: %{"prompt_tokens" => 999, "completion_tokens" => 999})

    assert [row] = rows_for(ctx.message.id)
    assert row.id == original_id
    assert row.prompt_tokens == 10
  end

  test "different usage_type or action_name are separate legitimate rows", ctx do
    assert {:ok, %{}} = record(ctx, [])
    assert {:ok, %{}} = record(ctx, usage_type: :tool_call)
    assert {:ok, %{}} = record(ctx, action_name: "generate_title")

    assert length(rows_for(ctx.message.id)) == 3
  end

  test "nil message_id (system operations) stays append-only", ctx do
    assert {:ok, %{}} = record(ctx, message_id: nil, usage_type: :embedding)
    assert {:ok, %{}} = record(ctx, message_id: nil, usage_type: :embedding)

    rows =
      Magus.Usage.MessageUsage
      |> Ash.Query.filter(is_nil(message_id) and usage_type == :embedding)
      |> Ash.Query.filter(conversation_id == ^ctx.conversation.id)
      |> Ash.read!(authorize?: false)

    assert length(rows) == 2
  end
end
