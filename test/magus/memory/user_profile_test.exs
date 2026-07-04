defmodule Magus.Memory.UserProfileTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Support.AiAgent

  @ai %AiAgent{}

  test "one profile per (user, nil-workspace) bucket, set_document rewrites in place" do
    user = generate(user())

    {:ok, profile} =
      Magus.Memory.create_user_profile(user.id, nil, %{document: "## Current Focus\nInitial"},
        actor: @ai
      )

    {:ok, fetched} = Magus.Memory.get_user_profile(user.id, nil, actor: @ai)
    assert fetched.id == profile.id

    {:ok, updated} =
      Magus.Memory.set_profile_document(profile, %{document: "## Current Focus\nRewritten"},
        actor: @ai
      )

    assert updated.document =~ "Rewritten"
    assert updated.token_estimate == div(String.length(updated.document), 4)
    refute is_nil(updated.last_distilled_at)
    assert updated.pending_notes == []

    # A second create in the same bucket violates the identity
    assert {:error, _} =
             Magus.Memory.create_user_profile(user.id, nil, %{document: "dup"}, actor: @ai)
  end

  test "set_document snapshots a version" do
    user = generate(user())
    {:ok, profile} = Magus.Memory.create_user_profile(user.id, nil, %{document: "v0"}, actor: @ai)
    {:ok, _} = Magus.Memory.set_profile_document(profile, %{document: "v1"}, actor: @ai)

    {:ok, versions} = Magus.Memory.list_profile_versions(profile.id, actor: @ai)
    assert Enum.any?(versions, &(&1.document == "v1"))
  end

  test "add_note appends and set_document drains notes" do
    user = generate(user())
    {:ok, profile} = Magus.Memory.create_user_profile(user.id, nil, %{document: ""}, actor: @ai)

    {:ok, with_note} =
      Magus.Memory.add_profile_note(profile, "prefers concise answers", actor: @ai)

    assert with_note.pending_notes == ["prefers concise answers"]

    {:ok, drained} =
      Magus.Memory.set_profile_document(with_note, %{document: "## Preferences\nConcise"},
        actor: @ai
      )

    assert drained.pending_notes == []
  end

  test "documents over 4000 chars are rejected" do
    user = generate(user())
    {:ok, profile} = Magus.Memory.create_user_profile(user.id, nil, %{document: ""}, actor: @ai)

    assert {:error, _} =
             Magus.Memory.set_profile_document(profile, %{document: String.duplicate("x", 4001)},
               actor: @ai
             )
  end

  test "another user cannot read the profile" do
    owner = generate(user())
    other = generate(user())
    {:ok, _} = Magus.Memory.create_user_profile(owner.id, nil, %{document: "secret"}, actor: @ai)

    assert {:error, _} = Magus.Memory.get_user_profile(owner.id, nil, actor: other)
  end
end
