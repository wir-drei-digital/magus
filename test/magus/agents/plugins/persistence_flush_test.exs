defmodule Magus.Agents.Plugins.PersistenceFlushTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Plugins.PersistencePlugin
  alias Magus.Chat

  setup do
    # Spawned flush task runs in a separate process; shared-mode sandbox lets it
    # reach the DB cleanly so no late ownership error prints after the test.
    Ecto.Adapters.SQL.Sandbox.mode(Magus.Repo, {:shared, self()})
    :ok
  end

  test "maybe_flush_queue/1 invokes flush for the conversation id" do
    # The plugin exposes a thin seam we can call directly; it must call
    # Steering.flush_conversation asynchronously and not raise.
    assert PersistencePlugin.maybe_flush_queue("00000000-0000-0000-0000-000000000000") == :ok

    # Let the fire-and-forget flush task finish (empty queue -> :ok) so its
    # output stays inside the test and the run remains pristine.
    Process.sleep(50)
  end

  test "cancelled ai.request.failed signal flushes the steering queue" do
    user = generate(user())
    {:ok, conv} = Chat.create_conversation(%{title: "q"}, actor: user)
    {:ok, queued} = Chat.enqueue_message(conv.id, %{text: "q"}, actor: user)
    assert queued.status == :queued

    # Minimal agent map: get_conversation_id/1 reads state[:conversation_id].
    signal = %{
      type: "ai.request.failed",
      data: %{error: {:cancelled, :user_cancelled}, request_id: Ash.UUID.generate()}
    }

    agent = %{id: "conv:#{conv.id}", state: %{conversation_id: conv.id}}

    assert {:ok, :continue} = PersistencePlugin.handle_signal(signal, %{agent: agent})

    # Flush is async (Task.Supervisor); shared sandbox lets it commit. Allow it
    # to run, then assert the queue drained (message promoted out of :queued).
    Process.sleep(100)

    assert Chat.list_queued_messages!(conv.id, actor: user) == []
  end
end
