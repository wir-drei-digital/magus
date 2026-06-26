defmodule Magus.Brain.Migrations.RebuildPageSourcesTest do
  use Magus.DataCase, async: true

  import Ecto.Query
  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.Migrations.RebuildPageSources
  alias Magus.Repo

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
    %{user: user, brain: brain, page: page}
  end

  defp set_body(page_id, body) do
    page_id_bin = Ecto.UUID.dump!(page_id)

    {1, _} =
      from(p in "brain_pages", where: p.id == ^page_id_bin)
      |> Repo.update_all(set: [body: body, updated_at: DateTime.utc_now()])

    :ok
  end

  defp create_source(brain_id, url) do
    Ash.create!(
      Ash.Changeset.for_create(Magus.Brain.Source, :create, %{
        brain_id: brain_id,
        url: url
      }),
      authorize?: false
    )
  end

  defp list_page_sources(page_id) do
    page_id_bin = Ecto.UUID.dump!(page_id)

    Repo.all(
      from ps in "brain_page_sources",
        where: ps.page_id == ^page_id_bin,
        order_by: [asc: ps.position],
        select: %{source_id: ps.source_id, position: ps.position}
    )
  end

  describe "run_batch/1" do
    test "links page to existing Source rows by URL", %{page: page, brain: brain} do
      src = create_source(brain.id, "https://a.example")

      body = """
      ```source
      url: https://a.example
      ```
      """

      set_body(page.id, body)
      assert {:ok, 1} = RebuildPageSources.run_batch()

      assert [link] = list_page_sources(page.id)
      assert link.source_id == Ecto.UUID.dump!(src.id)
      assert link.position == 0
    end

    test "preserves document order via position", %{page: page, brain: brain} do
      src_a = create_source(brain.id, "https://a.example")
      src_b = create_source(brain.id, "https://b.example")

      body = """
      ```source
      url: https://b.example
      ```

      ```source
      url: https://a.example
      ```
      """

      set_body(page.id, body)
      assert {:ok, 1} = RebuildPageSources.run_batch()

      sources = list_page_sources(page.id)
      assert length(sources) == 2
      [first, second] = sources
      assert first.source_id == Ecto.UUID.dump!(src_b.id)
      assert first.position == 0
      assert second.source_id == Ecto.UUID.dump!(src_a.id)
      assert second.position == 1
    end

    test "skips fences whose URL has no Source row yet", %{page: page} do
      body = """
      ```source
      url: https://orphan.example
      ```
      """

      set_body(page.id, body)
      assert {:ok, 1} = RebuildPageSources.run_batch()
      assert list_page_sources(page.id) == []
    end

    test "auto-disables on subsequent runs", %{page: page} do
      set_body(page.id, "no source fences")
      assert {:ok, 1} = RebuildPageSources.run_batch()
      assert {:ok, 0} = RebuildPageSources.run_batch()
    end
  end
end
