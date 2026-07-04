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
end
