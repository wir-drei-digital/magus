defmodule Magus.Agents.Actions.DistillUserProfileTest do
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.DistillUserProfile
  alias Magus.Agents.Support.AiAgent
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  @ai %AiAgent{}

  test "distills from recent local memories in the matching bucket" do
    user = generate(user())
    conv = generate(conversation(actor: user))

    {:ok, _} =
      Magus.Memory.create_memory(
        conv.id,
        user.id,
        "Lisbon move",
        %{content: %{}, summary: "User moved to Lisbon"},
        actor: user
      )

    {:ok, _} =
      Magus.Memory.create_user_memory(
        user.id,
        nil,
        "Old fact",
        %{content: %{}, summary: "Old fact"},
        actor: @ai
      )

    expect(LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
      assert prompt =~ "Lisbon move"
      refute prompt =~ "Old fact"
      assert prompt =~ "Recent Conversation Memories"

      MockResponses.generate_object_response(%{
        "document" => "## Current Focus\nLives in Lisbon."
      })
    end)

    assert {:ok, %{document: doc}} =
             DistillUserProfile.run(%{user_id: to_string(user.id), workspace_id: nil}, %{})

    assert doc =~ "Lisbon"
  end

  test "rewrites the profile from memories and pending notes, draining notes" do
    user = generate(user())
    conv = generate(conversation(actor: user))

    {:ok, _} =
      Magus.Memory.create_memory(
        conv.id,
        user.id,
        "Preferred Stack",
        %{content: %{}, summary: "Prefers Elixir and Phoenix for all projects"},
        actor: user
      )

    {:ok, profile} =
      Magus.Memory.create_user_profile(user.id, nil, %{document: "## Preferences\nOld"},
        actor: @ai
      )

    {:ok, _} =
      Magus.Memory.add_profile_note(profile, "responds well to short answers", actor: @ai)

    expect(LLMMock, :generate_object, fn _model, prompt, _schema, _opts ->
      assert prompt =~ "Prefers Elixir and Phoenix"
      assert prompt =~ "responds well to short answers"
      assert prompt =~ "## Preferences\nOld"

      MockResponses.generate_object_response(%{
        "document" => "## Preferences\nElixir/Phoenix. Short answers."
      })
    end)

    assert {:ok, %{document: doc}} =
             DistillUserProfile.run(%{user_id: to_string(user.id), workspace_id: nil}, %{})

    assert doc =~ "Elixir/Phoenix"

    {:ok, reloaded} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
    assert reloaded.document == doc
    assert reloaded.pending_notes == []
  end

  test "creates the profile row on first distillation" do
    user = generate(user())

    expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
      MockResponses.generate_object_response(%{"document" => "## Current Focus\nNothing yet"})
    end)

    assert {:ok, _} =
             DistillUserProfile.run(%{user_id: to_string(user.id), workspace_id: nil}, %{})

    assert {:ok, _profile} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
  end

  test "lost create race: still distills instead of erroring when another writer wins the insert" do
    user = generate(user())

    # Force the exact TOCTOU window `get_or_create_profile` opens: after its
    # own `get_user_profile` read misses (bucket doesn't exist yet) but
    # before its own `create_user_profile` call lands. Ecto emits a query
    # telemetry event per statement on the process that issued it; the
    # handler runs synchronously in that process, so inserting the
    # competing row from inside the handler (once, on the first miss)
    # guarantees `get_or_create_profile`'s own create is the one that hits
    # the real `unique_bucket` violation.
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

    expect(LLMMock, :generate_object, fn _model, _prompt, _schema, _opts ->
      MockResponses.generate_object_response(%{"document" => "## Preferences\nDistilled"})
    end)

    # Without the fix, `get_or_create_profile`'s own `create_user_profile`
    # call gets the `{:error, %Ash.Error.Invalid{}}` unique-index violation
    # from the row the telemetry handler just inserted, and `run/2`'s
    # `with` surfaces that error instead of falling back to it.
    assert {:ok, %{document: "## Preferences\nDistilled"}} =
             DistillUserProfile.run(%{user_id: to_string(user.id), workspace_id: nil}, %{})

    assert_received :race_row_inserted

    {:ok, reloaded} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
    assert reloaded.document == "## Preferences\nDistilled"
  end

  test "retries once when the document exceeds the cap, then errors" do
    user = generate(user())
    too_long = String.duplicate("y", 3500)

    expect(LLMMock, :generate_object, 2, fn _model, _prompt, _schema, _opts ->
      MockResponses.generate_object_response(%{"document" => too_long})
    end)

    assert {:error, :document_too_long} =
             DistillUserProfile.run(%{user_id: to_string(user.id), workspace_id: nil}, %{})
  end
end
