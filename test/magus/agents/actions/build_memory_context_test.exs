defmodule Magus.Agents.Actions.BuildMemoryContextTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Actions.BuildMemoryContext

  test "ambient (key-layer) injection does not bump last_accessed_at" do
    user = generate(user())
    conv = generate(conversation(actor: user))

    {:ok, memory} =
      Magus.Memory.create_memory(
        conv.id,
        user.id,
        "Ambient Memory",
        %{content: %{}, summary: "Injected by recency every turn"},
        actor: user
      )

    assert is_nil(memory.last_accessed_at)

    # Empty query_text skips the semantic layer entirely, so the only
    # retrieval is the ambient key layer.
    {:ok, context} =
      BuildMemoryContext.build(%{
        user_id: to_string(user.id),
        conversation_id: to_string(conv.id),
        query_text: "",
        global_enabled: false
      })

    assert Enum.any?(context.important, &(&1.id == memory.id))

    {:ok, reloaded} = Magus.Memory.get_memory(memory.id, actor: user)
    assert is_nil(reloaded.last_accessed_at)
  end
end
