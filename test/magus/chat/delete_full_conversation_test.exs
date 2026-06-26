defmodule Magus.Chat.DeleteFullConversationTest do
  @moduledoc """
  Conversation deletion enqueues remote sandbox destruction out of band rather
  than calling the provider (with Process.sleep retries) inside the delete
  transaction (magus-2621).
  """
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Chat

  defp seed_sandbox(conversation_id, sprite_id) do
    Ash.Seed.seed!(Magus.Sandbox.Sandbox, %{
      conversation_id: conversation_id,
      provider: :sprites,
      sprite_id: sprite_id
    })
  end

  test "enqueues DestroyRemoteSandbox for a sandbox with a sprite_id" do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{title: "Del"}, actor: user)
    seed_sandbox(conversation.id, "sprite-test-123")

    Chat.delete_full_conversation!(conversation, actor: user)

    assert_enqueued(
      worker: Magus.Sandbox.Workers.DestroyRemoteSandbox,
      args: %{"sprite_id" => "sprite-test-123", "provider" => "sprites"}
    )
  end

  test "does not enqueue when the sandbox has no sprite_id" do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{title: "Del2"}, actor: user)
    seed_sandbox(conversation.id, nil)

    Chat.delete_full_conversation!(conversation, actor: user)

    refute_enqueued(worker: Magus.Sandbox.Workers.DestroyRemoteSandbox)
  end
end
