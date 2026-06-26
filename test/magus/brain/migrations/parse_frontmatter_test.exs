defmodule Magus.Brain.Migrations.ParseFrontmatterTest do
  use Magus.DataCase, async: true

  import Ecto.Query
  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.Migrations.ParseFrontmatter
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

  describe "run_batch/1" do
    test "populates frontmatter from a body with a YAML block", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      set_body(page.id, "---\nicon: 🧠\ntags: [ml]\n---\n# Body\n")

      assert {:ok, 1} = ParseFrontmatter.run_batch()

      fm = get_frontmatter(page.id)
      assert fm["icon"] == "🧠"
      assert fm["tags"] == ["ml"]
    end

    test "marks a body without frontmatter with the _no_frontmatter sentinel", %{
      user: user,
      brain: brain
    } do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      set_body(page.id, "# Just a heading\n\nBody.\n")

      assert {:ok, 1} = ParseFrontmatter.run_batch()

      assert get_frontmatter(page.id) == %{"_no_frontmatter" => true}
    end

    test "flags malformed frontmatter with the _parse_error sentinel", %{
      user: user,
      brain: brain
    } do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      set_body(page.id, "---\nicon: [unterminated\n---\nbody\n")

      assert {:ok, 1} = ParseFrontmatter.run_batch()

      assert get_frontmatter(page.id) == %{"_parse_error" => true}
    end

    test "is idempotent: skips pages with non-empty frontmatter on subsequent runs", %{
      user: user,
      brain: brain
    } do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      set_body(page.id, "---\nicon: 🧠\n---\nbody\n")

      assert {:ok, 1} = ParseFrontmatter.run_batch()
      assert {:ok, 0} = ParseFrontmatter.run_batch()
    end

    test "skips pages with NULL body (haven't been body-backfilled yet)", %{
      user: user,
      brain: brain
    } do
      {:ok, _page} = Brain.create_page(brain.id, %{title: "No body yet"}, actor: user)

      assert {:ok, 0} = ParseFrontmatter.run_batch()
    end

    test "skips trashed pages", %{user: user, brain: brain} do
      {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
      set_body(page.id, "---\nicon: 🧠\n---\nx")
      {:ok, _} = Brain.soft_delete_page(page, actor: user)

      assert {:ok, 0} = ParseFrontmatter.run_batch()
    end
  end
end
