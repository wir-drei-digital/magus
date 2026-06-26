defmodule Magus.Brain.ActivityTest do
  @moduledoc """
  Tests for `Magus.Brain.Activity.list_brain_activity/2`. Verifies the
  page-version stream is mapped to UI entries correctly, sorted newest
  first, and respects the `:limit` option.
  """

  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.Activity

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    %{user: user, brain: brain}
  end

  describe "list_brain_activity/2" do
    test "returns empty list when the brain has no pages", %{brain: brain} do
      assert Activity.list_brain_activity(brain.id) == []
    end

    test "returns one entry per page version, newest first", %{user: user, brain: brain} do
      {:ok, page_a} = Brain.create_page(brain.id, %{title: "A"}, actor: user)
      {:ok, page_b} = Brain.create_page(brain.id, %{title: "B"}, actor: user)

      # Two body updates on A, one on B. update_body is the version-tracked
      # write path (see Page paper_trail config).
      {:ok, page_a} =
        Brain.update_page_body(page_a, %{body: "first", base_version: 0}, actor: user)

      {:ok, _page_a} =
        Brain.update_page_body(page_a, %{body: "second", base_version: page_a.lock_version},
          actor: user
        )

      {:ok, _page_b} =
        Brain.update_page_body(page_b, %{body: "only b", base_version: 0}, actor: user)

      entries = Activity.list_brain_activity(brain.id)

      assert length(entries) >= 3

      # Newest first across all pages in scope.
      assert entries ==
               Enum.sort_by(entries, & &1.inserted_at, {:desc, DateTime})
    end

    test "maps an :update_body version to the documented entry shape", %{
      user: user,
      brain: brain
    } do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Note"}, actor: user)

      body = "   Hello   world   from   markdown   "

      {:ok, _updated} = Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)

      entries = Activity.list_brain_activity(brain.id)
      entry = Enum.find(entries, &(&1.action_name == :update_body))

      assert entry
      assert entry.page_id == page.id
      assert entry.page_title == "Note"
      assert entry.contributor_id == user.id
      assert entry.contributor_type == :user
      assert is_struct(entry.inserted_at, DateTime)
      # Preview is whitespace-normalised first 80 chars of the new body.
      assert entry.preview == "Hello world from markdown"
    end

    test "produces empty preview for non-body actions (e.g. :update_title)", %{
      user: user,
      brain: brain
    } do
      {:ok, page} = Brain.create_page(brain.id, %{title: "Old"}, actor: user)
      {:ok, _renamed} = Brain.update_page_title(page, %{title: "New"}, actor: user)

      entries = Activity.list_brain_activity(brain.id)
      rename_entry = Enum.find(entries, &(&1.action_name == :update_title))

      assert rename_entry
      assert rename_entry.preview == ""
    end

    test "respects the :limit option", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)

      Enum.reduce(1..5, page, fn i, p ->
        {:ok, updated} =
          Brain.update_page_body(p, %{body: "v#{i}", base_version: p.lock_version}, actor: user)

        updated
      end)

      entries = Activity.list_brain_activity(brain.id, limit: 2)
      assert length(entries) == 2
    end

    test "is scoped to the requested brain", %{user: user, brain: brain} do
      {:ok, other_brain} = Brain.create_brain(%{title: "Other"}, actor: user)
      {:ok, other_page} = Brain.create_page(other_brain.id, %{title: "OP"}, actor: user)
      {:ok, _} = Brain.update_page_body(other_page, %{body: "x", base_version: 0}, actor: user)

      assert Activity.list_brain_activity(brain.id) == []
      assert length(Activity.list_brain_activity(other_brain.id)) >= 1
    end
  end
end
