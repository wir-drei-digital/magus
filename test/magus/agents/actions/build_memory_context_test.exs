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

  describe "profile injection" do
    test "injects the profile document and drops the global key-memory layer" do
      user =
        generate(user())
        |> Ash.Changeset.for_update(:update_profile_setting, %{profile_enabled: true},
          authorize?: false
        )
        |> Ash.update!()

      conv = generate(conversation(actor: user))
      ai = %Magus.Agents.Support.AiAgent{}

      {:ok, _} =
        Magus.Memory.create_user_memory(
          user.id,
          nil,
          "Global Key Memory",
          %{content: %{}, summary: "Would be injected by recency"},
          actor: ai
        )

      {:ok, _} =
        Magus.Memory.create_user_profile(
          user.id,
          nil,
          %{document: "## Preferences\nConcise answers, Elixir stack."},
          actor: ai
        )

      {:ok, context} =
        Magus.Agents.Actions.BuildMemoryContext.build(%{
          user_id: to_string(user.id),
          conversation_id: to_string(conv.id),
          query_text: "",
          global_enabled: true
        })

      assert context.profile_document =~ "Concise answers"
      assert context.formatted =~ "### User Profile"
      assert context.formatted =~ "Concise answers"
      refute Enum.any?(context.important, &(&1.display_scope == :user))
    end

    test "falls back to global key memories when no profile exists" do
      user =
        generate(user())
        |> Ash.Changeset.for_update(:update_profile_setting, %{profile_enabled: true},
          authorize?: false
        )
        |> Ash.update!()

      conv = generate(conversation(actor: user))
      ai = %Magus.Agents.Support.AiAgent{}

      {:ok, _} =
        Magus.Memory.create_user_memory(
          user.id,
          nil,
          "Global Key Memory",
          %{content: %{}, summary: "Injected by recency"},
          actor: ai
        )

      {:ok, context} =
        Magus.Agents.Actions.BuildMemoryContext.build(%{
          user_id: to_string(user.id),
          conversation_id: to_string(conv.id),
          query_text: "",
          global_enabled: true
        })

      assert is_nil(context.profile_document)
      assert Enum.any?(context.important, &(&1.display_scope == :user))
    end
  end
end
