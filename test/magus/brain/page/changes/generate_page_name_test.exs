defmodule Magus.Brain.Page.Changes.GeneratePageNameTest do
  use Magus.ResourceCase, async: true

  alias Magus.Brain

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Test Brain"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{}, actor: user)
    %{user: user, brain: brain, page: page}
  end

  # Helper: supply `base_version` from the current row so the optimistic
  # lock in `update_body` always succeeds. These tests don't care about
  # concurrent writes — they just want to seed body content.
  defp set_body!(page, body, user) do
    {:ok, updated} =
      Brain.update_page_body(page, %{body: body, base_version: page.lock_version}, actor: user)

    updated
  end

  describe "generate_name action (body-based)" do
    test "sets title from first H1 in body", %{user: user, page: page} do
      page = set_body!(page, "# Machine Learning Overview\n\nSome notes.", user)

      {:ok, updated} =
        Ash.Changeset.for_update(page, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert updated.title == "Machine Learning Overview"
    end

    test "skips frontmatter and uses first H1 after it", %{user: user, page: page} do
      body = """
      ---
      icon: 🧠
      tags: [ml, research]
      ---

      # Real Title

      Body content here.
      """

      page = set_body!(page, body, user)

      {:ok, updated} =
        Ash.Changeset.for_update(page, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert updated.title == "Real Title"
    end

    test "leaves title nil when body has no H1", %{user: user, page: page} do
      page = set_body!(page, "## Just an H2\n\nAnd a paragraph. No level-1 heading.", user)

      {:ok, unchanged} =
        Ash.Changeset.for_update(page, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert is_nil(unchanged.title)
    end

    test "leaves title nil when body is nil (coexistence-window race)", %{page: page} do
      # Page was created with no body and no title.
      assert is_nil(page.body)
      assert is_nil(page.title)

      {:ok, unchanged} =
        Ash.Changeset.for_update(page, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert is_nil(unchanged.title)
    end

    test "leaves title nil when body is empty string", %{user: user, page: page} do
      page = set_body!(page, "", user)

      {:ok, unchanged} =
        Ash.Changeset.for_update(page, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert is_nil(unchanged.title)
    end

    test "skips when title is already set", %{user: user, page: page} do
      {:ok, page} = Brain.update_page_title(page, %{title: "Custom Name"}, actor: user)
      page = set_body!(page, "# A Different Heading\n", user)

      {:ok, unchanged} =
        Ash.Changeset.for_update(page, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert unchanged.title == "Custom Name"
    end

    test "picks the first H1 when body contains several", %{user: user, page: page} do
      page =
        set_body!(page, "# First Title\n\nSome text.\n\n# Second Title\n\nMore text.\n", user)

      {:ok, updated} =
        Ash.Changeset.for_update(page, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert updated.title == "First Title"
    end

    test "trims whitespace around the H1 text", %{user: user, page: page} do
      page = set_body!(page, "#   Spaced Out   \n\nBody.\n", user)

      {:ok, updated} =
        Ash.Changeset.for_update(page, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert updated.title == "Spaced Out"
    end

    test "ignores '#' that isn't followed by a space (e.g. tags like '#ml')",
         %{user: user, page: page} do
      # `#ml` is a tag, not a heading. Without a space, it must not be
      # treated as an H1. The H2 doesn't count either; title stays nil.
      page = set_body!(page, "#ml\n\n## Subheading\n\nSome notes #more-tags here.\n", user)

      {:ok, unchanged} =
        Ash.Changeset.for_update(page, :generate_name, %{})
        |> Ash.update(authorize?: false)

      assert is_nil(unchanged.title)
    end
  end
end
