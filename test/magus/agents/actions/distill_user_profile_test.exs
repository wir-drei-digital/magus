defmodule Magus.Agents.Actions.DistillUserProfileTest do
  use Magus.ResourceCase, async: true

  import Mox

  alias Magus.Agents.Actions.DistillUserProfile
  alias Magus.Agents.Support.AiAgent
  alias Magus.Test.Mocks.LLMMock
  alias Magus.Test.MockResponses

  setup :verify_on_exit!

  @ai %AiAgent{}

  test "rewrites the profile from memories and pending notes, draining notes" do
    user = generate(user())

    {:ok, _} =
      Magus.Memory.create_user_memory(
        user.id,
        nil,
        "Preferred Stack",
        %{content: %{}, summary: "Prefers Elixir and Phoenix for all projects"},
        actor: @ai
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
