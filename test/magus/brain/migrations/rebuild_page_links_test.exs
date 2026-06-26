defmodule Magus.Brain.Migrations.RebuildPageLinksTest do
  use Magus.DataCase, async: true

  import Ecto.Query
  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.Migrations.RebuildPageLinks
  alias Magus.Repo

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    %{user: user, brain: brain}
  end

  defp set_body(page_id, body) do
    page_id_bin = Ecto.UUID.dump!(page_id)

    {1, _} =
      from(p in "brain_pages", where: p.id == ^page_id_bin)
      |> Repo.update_all(set: [body: body, updated_at: DateTime.utc_now()])

    :ok
  end

  defp get_frontmatter(page_id) do
    page_id_bin = Ecto.UUID.dump!(page_id)
    Repo.one(from p in "brain_pages", where: p.id == ^page_id_bin, select: p.frontmatter)
  end

  defp list_links(page_id) do
    page_id_bin = Ecto.UUID.dump!(page_id)

    Repo.all(
      from l in "brain_page_links",
        where: l.source_page_id == ^page_id_bin,
        select: %{
          target_page_id: l.target_page_id,
          target_title_at_link_time: l.target_title_at_link_time
        }
    )
  end

  describe "run_batch/1" do
    test "resolves wikilinks to target page ids", %{user: user, brain: brain} do
      {:ok, source_page} = Brain.create_page(brain.id, %{title: "Source"}, actor: user)
      {:ok, target_page} = Brain.create_page(brain.id, %{title: "Target"}, actor: user)

      set_body(source_page.id, "See [[Target]] for more")

      assert {:ok, 1} = RebuildPageLinks.run_batch()

      links = list_links(source_page.id)
      assert length(links) == 1
      [link] = links
      assert link.target_page_id == Ecto.UUID.dump!(target_page.id)
      assert link.target_title_at_link_time == "Target"
    end

    test "is case-insensitive on title resolution", %{user: user, brain: brain} do
      {:ok, source_page} = Brain.create_page(brain.id, %{title: "Src"}, actor: user)
      {:ok, _target_page} = Brain.create_page(brain.id, %{title: "Important"}, actor: user)

      set_body(source_page.id, "See [[important]]")
      assert {:ok, 1} = RebuildPageLinks.run_batch()
      assert length(list_links(source_page.id)) == 1
    end

    test "skips broken wikilinks (no matching target page)", %{user: user, brain: brain} do
      {:ok, source_page} = Brain.create_page(brain.id, %{title: "Src"}, actor: user)
      set_body(source_page.id, "Reference to [[NonExistent]]")

      assert {:ok, 1} = RebuildPageLinks.run_batch()
      assert list_links(source_page.id) == []
    end

    test "ignores [[msg:...]] references", %{user: user, brain: brain} do
      {:ok, source_page} = Brain.create_page(brain.id, %{title: "Src"}, actor: user)

      set_body(
        source_page.id,
        "[[msg:#{Ash.UUID.generate()}]] and [[msg:#{Ash.UUID.generate()}|preview]]"
      )

      assert {:ok, 1} = RebuildPageLinks.run_batch()
      assert list_links(source_page.id) == []
    end

    test "marks page as built via frontmatter sentinel", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      set_body(page.id, "no links here")

      assert {:ok, 1} = RebuildPageLinks.run_batch()
      fm = get_frontmatter(page.id)
      assert is_binary(fm["_links_built_at"])
    end

    test "auto-disables: subsequent run skips processed pages", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      set_body(page.id, "anything")

      assert {:ok, 1} = RebuildPageLinks.run_batch()
      assert {:ok, 0} = RebuildPageLinks.run_batch()
    end
  end
end
