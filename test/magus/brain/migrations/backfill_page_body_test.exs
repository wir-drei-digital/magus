defmodule Magus.Brain.Migrations.BackfillPageBodyTest do
  use Magus.DataCase, async: true

  import Magus.Generators
  import Magus.Brain.MigrationsTestHelpers, only: [insert_block!: 2]

  alias Magus.Brain
  alias Magus.Brain.Migrations.BackfillPageBody

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    %{user: user, brain: brain}
  end

  defp create_block(page_id, attrs) do
    {:ok, insert_block!(page_id, attrs)}
  end

  describe "run_batch/1" do
    test "renders blocks to markdown and sets body on pages with body IS NULL", %{
      user: user,
      brain: brain
    } do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      {:ok, _} = create_block(page.id, %{type: :heading, content: %{"text" => "Title"}})

      {:ok, _} =
        create_block(page.id, %{type: :paragraph, content: %{"text" => "Body text"}})

      assert {:ok, 1} = BackfillPageBody.run_batch()

      {:ok, refreshed} = Brain.get_page(page.id, actor: user)
      assert refreshed.body =~ "Title"
      assert refreshed.body =~ "Body text"
    end

    test "is idempotent: a second run on the same pages does no work", %{
      user: user,
      brain: brain
    } do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      {:ok, _} = create_block(page.id, %{type: :paragraph, content: %{"text" => "x"}})

      assert {:ok, 1} = BackfillPageBody.run_batch()
      assert {:ok, 0} = BackfillPageBody.run_batch()
    end

    test "respects the batch size", %{user: user, brain: brain} do
      Enum.each(1..5, fn n ->
        {:ok, page} = Brain.create_page(brain.id, %{title: "P#{n}"}, actor: user)
        {:ok, _} = create_block(page.id, %{type: :paragraph, content: %{"text" => "x"}})
      end)

      assert {:ok, 2} = BackfillPageBody.run_batch(2)
      assert {:ok, 2} = BackfillPageBody.run_batch(2)
      assert {:ok, 1} = BackfillPageBody.run_batch(2)
      assert {:ok, 0} = BackfillPageBody.run_batch(2)
    end

    test "skips trashed pages", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      {:ok, _} = create_block(page.id, %{type: :paragraph, content: %{"text" => "x"}})
      {:ok, _} = Brain.soft_delete_page(page, actor: user)

      assert {:ok, 0} = BackfillPageBody.run_batch()
    end

    test "drops source-block children from the rendered body", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)

      {:ok, source} =
        create_block(page.id, %{
          type: :source,
          content: %{"url" => "https://example.com", "title" => "X"}
        })

      {:ok, _child} =
        create_block(page.id, %{
          type: :paragraph,
          content: %{"text" => "ingested content"},
          parent_block_id: source.id
        })

      assert {:ok, 1} = BackfillPageBody.run_batch()

      {:ok, refreshed} = Brain.get_page(page.id, actor: user)
      assert refreshed.body =~ "```source"
      assert refreshed.body =~ "https://example.com"
      refute refreshed.body =~ "ingested content"
    end

    test "does NOT create a paper-trail version when backfilling body", %{
      user: user,
      brain: brain
    } do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      {:ok, _} = create_block(page.id, %{type: :paragraph, content: %{"text" => "x"}})

      versions_before = page_version_count(page.id)
      assert {:ok, 1} = BackfillPageBody.run_batch()
      versions_after = page_version_count(page.id)

      assert versions_after == versions_before
    end

    test "re-runs on the new-page race: body=\"\" with blocks now present is picked up", %{
      user: user,
      brain: brain
    } do
      # Simulate the race: first tick fired before any blocks existed and
      # wrote body="". Then blocks landed. Next tick MUST pick the page up
      # again and re-render, not skip it (was the core sentinel-lock bug).
      {:ok, page} = Brain.create_page(brain.id, %{title: "Race"}, actor: user)

      # First tick: no blocks yet → body becomes "".
      assert {:ok, 1} = BackfillPageBody.run_batch()

      {:ok, refreshed_first} = Brain.get_page(page.id, actor: user)
      assert refreshed_first.body == ""

      # Now blocks land.
      {:ok, _} =
        create_block(page.id, %{type: :paragraph, content: %{"text" => "Real content"}})

      # Second tick: race-fix query picks the page up again.
      assert {:ok, 1} = BackfillPageBody.run_batch()

      {:ok, refreshed_second} = Brain.get_page(page.id, actor: user)
      assert refreshed_second.body =~ "Real content"
    end
  end

  defp page_version_count(page_id) do
    require Ash.Query

    Magus.Brain.Page.Version
    |> Ash.Query.filter(version_source_id == ^page_id)
    |> Ash.read!(authorize?: false)
    |> length()
  end
end
