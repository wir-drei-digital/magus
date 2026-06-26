defmodule Magus.Brain.ListBacklinksTest do
  @moduledoc """
  Phase C5 sanity tests for the `Magus.Brain.list_backlinks/2` code
  interface (the `PageLink.backlinks_for` action). Covers the
  rename-drift case the Related-pages panel uses to flag stale link
  text against the current title.
  """

  use Magus.DataCase, async: true

  import Ecto.Query
  import Magus.Generators

  alias Magus.Brain
  alias Magus.Repo

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    %{user: user, brain: brain}
  end

  defp upsert_link!(source_page_id, target_page_id, target_title_at_link_time) do
    # The Phase A rebuild pipeline is the only sanctioned writer (PageLink
    # `create` has `forbid_if always()`); tests reach the table directly via
    # the public `RebuildPageLinks` migration worker. Setting the source
    # body to `[[<target_title>]]` causes the worker to (a) resolve the
    # target via case-insensitive title match and (b) record the wikilink
    # text as `target_title_at_link_time`.
    src_bin = Ecto.UUID.dump!(source_page_id)

    {1, _} =
      from(p in "brain_pages", where: p.id == ^src_bin)
      |> Repo.update_all(set: [body: "See [[#{target_title_at_link_time}]]"])

    {:ok, _} = Magus.Brain.Migrations.RebuildPageLinks.run_batch()
    _ = target_page_id
    :ok
  end

  describe "list_backlinks/2" do
    test "returns rows whose target is the given page", %{user: user, brain: brain} do
      {:ok, source} = Brain.create_page(brain.id, %{title: "Source"}, actor: user)
      {:ok, target} = Brain.create_page(brain.id, %{title: "Target"}, actor: user)

      upsert_link!(source.id, target.id, "Target")

      assert {:ok, links} =
               Brain.list_backlinks(target.id, load: [:source_page], actor: user)

      assert [%{source_page_id: source_id, target_title_at_link_time: "Target"}] = links
      assert source_id == source.id
    end

    test "exposes drift between link text and current target title", %{
      user: user,
      brain: brain
    } do
      {:ok, source} = Brain.create_page(brain.id, %{title: "Source"}, actor: user)
      {:ok, target} = Brain.create_page(brain.id, %{title: "Original"}, actor: user)

      upsert_link!(source.id, target.id, "Original")

      # Rename the target page; the link text in source's body is now stale.
      {:ok, renamed} = Brain.update_page_title(target, %{title: "Renamed"}, actor: user)

      assert {:ok, [link]} =
               Brain.list_backlinks(renamed.id, load: [:source_page], actor: user)

      assert link.target_title_at_link_time == "Original"
      assert link.source_page.title == "Source"
    end

    test "returns [] when no page links to the target", %{user: user, brain: brain} do
      {:ok, target} = Brain.create_page(brain.id, %{title: "Lonely"}, actor: user)
      assert {:ok, []} = Brain.list_backlinks(target.id, actor: user)
    end
  end
end
