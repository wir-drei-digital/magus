defmodule Magus.Brain.Migrations.BackfillPageChunksTest do
  use Magus.DataCase, async: true

  import Ecto.Query
  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.Migrations.BackfillPageChunks
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

  defp chunk_count(page_id) do
    page_id_bin = Ecto.UUID.dump!(page_id)
    Repo.one(from c in "brain_page_chunks", where: c.page_id == ^page_id_bin, select: count(c.id))
  end

  describe "run_batch/1" do
    test "chunks the body and inserts rows with embedding: nil", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      set_body(page.id, "Para one.\n\nPara two.\n\nPara three.")

      assert {:ok, 1} = BackfillPageChunks.run_batch()
      assert chunk_count(page.id) >= 1
    end

    test "is idempotent: page already chunked is not re-processed", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      set_body(page.id, "Body text.")

      assert {:ok, 1} = BackfillPageChunks.run_batch()
      before_count = chunk_count(page.id)
      assert {:ok, 0} = BackfillPageChunks.run_batch()
      assert chunk_count(page.id) == before_count
    end

    test "skips pages with NULL body", %{user: user, brain: brain} do
      {:ok, _page} = Brain.create_page(brain.id, %{title: "Empty"}, actor: user)
      assert {:ok, 0} = BackfillPageChunks.run_batch()
    end

    test "skips pages with empty-string body", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      set_body(page.id, "")
      assert {:ok, 0} = BackfillPageChunks.run_batch()
      assert chunk_count(page.id) == 0
    end

    test "skips trashed pages", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      set_body(page.id, "Body.")
      {:ok, _} = Brain.soft_delete_page(page, actor: user)

      assert {:ok, 0} = BackfillPageChunks.run_batch()
    end
  end
end
