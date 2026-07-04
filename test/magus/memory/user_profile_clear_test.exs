defmodule Magus.Memory.UserProfileClearTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Support.AiAgent
  @ai %AiAgent{}

  test "clear empties the document and snapshots a version; owner authorized" do
    user = generate(user())

    {:ok, profile} =
      Magus.Memory.create_user_profile(user.id, nil, %{document: "## Focus\nX"}, actor: @ai)

    {:ok, cleared} =
      profile
      |> Ash.Changeset.for_update(:clear, %{}, actor: user)
      |> Ash.update()

    assert cleared.document == ""
    assert cleared.token_estimate == 0
    {:ok, versions} = Magus.Memory.list_profile_versions(profile.id, actor: @ai)
    assert length(versions) >= 1
  end

  test "a different user cannot clear someone else's profile" do
    owner = generate(user())
    other = generate(user())

    {:ok, profile} =
      Magus.Memory.create_user_profile(owner.id, nil, %{document: "secret"}, actor: @ai)

    assert {:error, _} =
             profile |> Ash.Changeset.for_update(:clear, %{}, actor: other) |> Ash.update()
  end
end
