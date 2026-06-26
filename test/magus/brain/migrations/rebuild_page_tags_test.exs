defmodule Magus.Brain.Migrations.RebuildPageTagsTest do
  use Magus.DataCase, async: true

  import Ecto.Query
  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.Migrations.RebuildPageTags
  alias Magus.Repo

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
    %{user: user, brain: brain, page: page}
  end

  defp set_body_and_frontmatter(page_id, body, frontmatter) do
    page_id_bin = Ecto.UUID.dump!(page_id)

    {1, _} =
      from(p in "brain_pages", where: p.id == ^page_id_bin)
      |> Repo.update_all(
        set: [body: body, frontmatter: frontmatter, updated_at: DateTime.utc_now()]
      )

    :ok
  end

  defp list_tags(page_id) do
    page_id_bin = Ecto.UUID.dump!(page_id)

    Repo.all(
      from t in "brain_page_tags",
        where: t.page_id == ^page_id_bin,
        select: %{tag: t.tag, source: t.source}
    )
  end

  describe "run_batch/1" do
    test "extracts inline #tag occurrences as :inline source", %{page: page} do
      set_body_and_frontmatter(page.id, "Working on #ml and #research today.", %{})

      assert {:ok, 1} = RebuildPageTags.run_batch()

      tags = list_tags(page.id) |> Enum.sort_by(& &1.tag)
      assert tags == [%{tag: "ml", source: "inline"}, %{tag: "research", source: "inline"}]
    end

    test "extracts frontmatter tags list as :frontmatter source", %{page: page} do
      set_body_and_frontmatter(page.id, "no inline tags", %{"tags" => ["ml", "research"]})

      assert {:ok, 1} = RebuildPageTags.run_batch()

      tags = list_tags(page.id) |> Enum.sort_by(& &1.tag)

      assert tags == [
               %{tag: "ml", source: "frontmatter"},
               %{tag: "research", source: "frontmatter"}
             ]
    end

    test "frontmatter wins when both sources mention the same tag", %{page: page} do
      set_body_and_frontmatter(page.id, "About #ml stuff", %{"tags" => ["ml"]})

      assert {:ok, 1} = RebuildPageTags.run_batch()
      assert [%{tag: "ml", source: "frontmatter"}] = list_tags(page.id)
    end

    test "auto-disables on subsequent runs once frontmatter cache is populated", %{
      page: page
    } do
      # ParseFrontmatter has already run and set a non-empty frontmatter cache;
      # only then is RebuildPageTags safe to sentinel (without it, frontmatter
      # tags would be missing from the rebuild and we'd lock-out an incomplete
      # tag set).
      set_body_and_frontmatter(page.id, "no tags", %{"_no_frontmatter" => true})
      assert {:ok, 1} = RebuildPageTags.run_batch()
      assert {:ok, 0} = RebuildPageTags.run_batch()
    end

    test "does NOT sentinel when frontmatter cache hasn't been populated yet", %{page: page} do
      # Phase B race: page body was backfilled but ParseFrontmatter hasn't
      # run yet. If we sentineled now we'd permanently lock out frontmatter
      # tags. Leave the sentinel unset so the next tick retries.
      set_body_and_frontmatter(page.id, "no tags", %{})

      assert {:ok, 1} = RebuildPageTags.run_batch()
      # Sentinel still missing — second run picks up the same page again.
      assert {:ok, 1} = RebuildPageTags.run_batch()
    end
  end
end
