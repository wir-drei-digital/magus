defmodule Magus.Agents.Tools.Memory.UpdateProfileTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Support.AiAgent
  alias Magus.Agents.Tools.Memory.UpdateProfile

  @ai %AiAgent{}

  describe "display_name/0 and summarize_output/1" do
    test "provides display_name" do
      assert UpdateProfile.display_name() == "Update Profile"
    end

    test "summarizes output correctly" do
      assert UpdateProfile.summarize_output(%{status: "queued", pending_notes: 1}) ==
               "Profile note queued"

      assert UpdateProfile.summarize_output(%{}) == "Profile note queued"
    end
  end

  test "queues a note on the bucket profile, creating the profile if needed" do
    user = generate(user())
    conv = generate(conversation(actor: user))

    context = %{user_id: user.id, conversation_id: conv.id}

    assert {:ok, %{status: "queued", pending_notes: 1}} =
             UpdateProfile.run(%{note: "prefers step-by-step plans"}, context)

    {:ok, profile} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
    assert profile.pending_notes == ["prefers step-by-step plans"]
  end

  test "queues a second note onto an existing profile without creating a duplicate" do
    user = generate(user())
    conv = generate(conversation(actor: user))

    context = %{user_id: user.id, conversation_id: conv.id}

    assert {:ok, %{status: "queued", pending_notes: 1}} =
             UpdateProfile.run(%{note: "first note"}, context)

    assert {:ok, %{status: "queued", pending_notes: 2}} =
             UpdateProfile.run(%{note: "second note"}, context)

    {:ok, profile} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
    assert profile.pending_notes == ["first note", "second note"]
  end

  test "errors without required context" do
    assert {:error, _} = UpdateProfile.run(%{note: "x"}, %{})
  end

  test "lost create race: still queues the note instead of erroring when another writer wins" do
    user = generate(user())
    conv = generate(conversation(actor: user))
    context = %{user_id: user.id, conversation_id: conv.id}

    # Force the exact TOCTOU window `get_or_create` opens: after its own
    # `get_user_profile` read misses (bucket doesn't exist yet) but before
    # its own `create_user_profile` call lands. Ecto emits a query telemetry
    # event per statement on the process that issued it; the handler runs
    # synchronously in that process, so inserting the competing row from
    # inside the handler (once, on the first miss) guarantees
    # `get_or_create`'s own create is the one that hits the real
    # `unique_bucket` violation. Only the tool's own call ever queues a
    # note, so this isolates the get-or-create re-read path from any
    # separate concurrent-`add_note` behavior.
    test_pid = self()
    handler_id = {:profile_race, make_ref()}
    armed = :counters.new(1, [])

    :telemetry.attach(
      handler_id,
      [:magus, :repo, :query],
      fn _event, _measurements, %{source: source, result: result}, _config ->
        with "user_profiles" <- source,
             {:ok, %{num_rows: 0}} <- result,
             0 <- :counters.get(armed, 1) do
          :counters.add(armed, 1, 1)

          {:ok, _} =
            Magus.Memory.create_user_profile(user.id, nil, %{document: ""}, actor: @ai)

          send(test_pid, :race_row_inserted)
        else
          _ -> :ok
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Without the fix, `get_or_create`'s own `create_user_profile` call gets
    # the `{:error, %Ash.Error.Invalid{}}` unique-index violation from the
    # row the telemetry handler just inserted, and `run/2`'s `with`/`else`
    # surfaces that error instead of queuing the note.
    assert {:ok, %{status: "queued", pending_notes: 1}} =
             UpdateProfile.run(%{note: "prefers step-by-step plans"}, context)

    assert_received :race_row_inserted

    {:ok, profile} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
    assert profile.pending_notes == ["prefers step-by-step plans"]
  end
end
