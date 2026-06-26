defmodule Magus.Brain.Page.UpdateBodyTest do
  @moduledoc """
  Tests for the Phase C `Page.update_body` action: the single write path
  for page content. Covers the optimistic-lock validation, file-workspace
  guard, and the inline rebuild of every derived index (frontmatter
  cache, page links, sources + page_sources, page_tags, page_chunks).
  """

  use Magus.DataCase, async: true

  import Ecto.Query
  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.Page.Errors.VersionConflict
  alias Magus.Repo

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "P"}, actor: user)
    %{user: user, brain: brain, page: page}
  end

  defp set_frontmatter!(page_id, frontmatter) do
    page_id_bin = Ecto.UUID.dump!(page_id)

    {1, _} =
      from(p in "brain_pages", where: p.id == ^page_id_bin)
      |> Repo.update_all(set: [frontmatter: frontmatter, updated_at: DateTime.utc_now()])

    :ok
  end

  defp count_chunks(page_id) do
    page_id_bin = Ecto.UUID.dump!(page_id)
    Repo.one(from c in "brain_page_chunks", where: c.page_id == ^page_id_bin, select: count(c.id))
  end

  defp count_links(source_page_id) do
    src_bin = Ecto.UUID.dump!(source_page_id)

    Repo.one(
      from l in "brain_page_links",
        where: l.source_page_id == ^src_bin,
        select: count(l.id)
    )
  end

  defp list_links(source_page_id) do
    src_bin = Ecto.UUID.dump!(source_page_id)

    Repo.all(
      from l in "brain_page_links",
        where: l.source_page_id == ^src_bin,
        select: %{
          target_page_id: l.target_page_id,
          target_title_at_link_time: l.target_title_at_link_time
        }
    )
  end

  defp list_tags(page_id) do
    page_id_bin = Ecto.UUID.dump!(page_id)

    Repo.all(
      from t in "brain_page_tags",
        where: t.page_id == ^page_id_bin,
        order_by: [asc: t.tag],
        select: %{tag: t.tag, source: t.source}
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

  describe "update_body basics" do
    test "sets body, bumps lock_version, populates frontmatter cache", %{user: user, page: page} do
      body =
        "---\nicon: 🧠\ntags: [ml, research]\n---\n# Hello\n\nBody text.\n"

      assert {:ok, updated} =
               Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)

      assert updated.body == body
      assert updated.lock_version == 1
      assert updated.frontmatter == %{"icon" => "🧠", "tags" => ["ml", "research"]}
    end

    test "successive updates bump lock_version monotonically", %{user: user, page: page} do
      {:ok, v1} = Brain.update_page_body(page, %{body: "one", base_version: 0}, actor: user)
      {:ok, v2} = Brain.update_page_body(v1, %{body: "two", base_version: 1}, actor: user)
      assert v2.lock_version == 2
      assert v2.body == "two"
    end

    test "body with no frontmatter results in empty frontmatter cache", %{user: user, page: page} do
      {:ok, updated} =
        Brain.update_page_body(page, %{body: "just body, no fm", base_version: 0}, actor: user)

      assert updated.body == "just body, no fm"
      assert updated.frontmatter == %{}
    end
  end

  describe "frontmatter sentinel handling" do
    test "strips Phase B sentinel keys from the persisted frontmatter cache", %{
      user: user,
      page: page
    } do
      # Simulate Phase B cron workers having seeded sentinels on the page.
      set_frontmatter!(page.id, %{
        "_no_frontmatter" => true,
        "_parse_error" => true,
        "_links_built_at" => "2026-05-28T00:00:00Z",
        "_sources_built_at" => "2026-05-28T00:00:00Z",
        "_tags_built_at" => "2026-05-28T00:00:00Z"
      })

      {:ok, updated} =
        Brain.update_page_body(page, %{body: "anything", base_version: 0}, actor: user)

      keys = Map.keys(updated.frontmatter)
      refute "_no_frontmatter" in keys
      refute "_parse_error" in keys
      refute "_links_built_at" in keys
      refute "_sources_built_at" in keys
      refute "_tags_built_at" in keys
    end

    test "strips sentinels from the parsed frontmatter too", %{user: user, page: page} do
      # Even if (impossibly) a user wrote a sentinel-looking key into their
      # YAML, we strip it: the save pipeline owns these keys.
      body = """
      ---
      icon: 🧠
      _links_built_at: "user-set"
      ---

      # Body
      """

      {:ok, updated} =
        Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)

      assert updated.frontmatter == %{"icon" => "🧠"}
    end
  end

  describe "chunking" do
    test "creates brain_page_chunks rows from the body", %{user: user, page: page} do
      body = "Para one.\n\nPara two.\n\nPara three."
      {:ok, _} = Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)

      assert count_chunks(page.id) >= 1
    end

    test "re-chunks on subsequent updates: existing chunks are replaced not duplicated", %{
      user: user,
      page: page
    } do
      {:ok, v1} =
        Brain.update_page_body(page, %{body: "first body", base_version: 0}, actor: user)

      first_count = count_chunks(page.id)
      assert first_count >= 1

      {:ok, _v2} =
        Brain.update_page_body(
          v1,
          %{body: "second body content goes here", base_version: 1},
          actor: user
        )

      second_count = count_chunks(page.id)

      # The chunks should be replaced (not added on top of the originals).
      # For these tiny bodies both produce exactly one chunk; the key
      # assertion is that we never accumulate stale chunks across saves.
      assert second_count >= 1
      assert second_count <= first_count + 1

      # Content check: the chunk row should reference the NEW body, not the old.
      page_id_bin = Ecto.UUID.dump!(page.id)

      contents =
        Repo.all(
          from c in "brain_page_chunks", where: c.page_id == ^page_id_bin, select: c.content
        )

      assert Enum.any?(contents, &(&1 =~ "second body"))
      refute Enum.any?(contents, &(&1 =~ "first body"))
    end

    test "empty body deletes existing chunks", %{user: user, page: page} do
      {:ok, v1} =
        Brain.update_page_body(page, %{body: "had content", base_version: 0}, actor: user)

      assert count_chunks(page.id) >= 1

      {:ok, _v2} = Brain.update_page_body(v1, %{body: "", base_version: 1}, actor: user)
      assert count_chunks(page.id) == 0
    end
  end

  describe "wikilinks" do
    test "populates brain_page_links for [[Page Name]] wikilinks", %{
      user: user,
      brain: brain,
      page: page
    } do
      {:ok, target} = Brain.create_page(brain.id, %{title: "Target"}, actor: user)

      {:ok, _} =
        Brain.update_page_body(
          page,
          %{body: "See [[Target]] for more", base_version: 0},
          actor: user
        )

      assert [link] = list_links(page.id)
      assert link.target_page_id == Ecto.UUID.dump!(target.id)
      assert link.target_title_at_link_time == "Target"
    end

    test "resolves wikilink targets case-insensitively", %{
      user: user,
      brain: brain,
      page: page
    } do
      {:ok, _target} = Brain.create_page(brain.id, %{title: "Important"}, actor: user)

      {:ok, _} =
        Brain.update_page_body(
          page,
          %{body: "See [[important]]", base_version: 0},
          actor: user
        )

      assert count_links(page.id) == 1
    end

    test "skips [[msg:...]] message references", %{user: user, page: page} do
      msg_ref = "[[msg:#{Ash.UUID.generate()}]]"

      {:ok, _} =
        Brain.update_page_body(page, %{body: msg_ref, base_version: 0}, actor: user)

      assert count_links(page.id) == 0
    end

    test "skips wikilinks whose target page does not exist", %{user: user, page: page} do
      {:ok, _} =
        Brain.update_page_body(
          page,
          %{body: "See [[NonExistent]]", base_version: 0},
          actor: user
        )

      assert count_links(page.id) == 0
    end

    test "re-running update_body replaces wikilinks not adds them", %{
      user: user,
      brain: brain,
      page: page
    } do
      {:ok, _t1} = Brain.create_page(brain.id, %{title: "A"}, actor: user)
      {:ok, _t2} = Brain.create_page(brain.id, %{title: "B"}, actor: user)

      {:ok, v1} =
        Brain.update_page_body(page, %{body: "See [[A]]", base_version: 0}, actor: user)

      assert count_links(page.id) == 1

      {:ok, _v2} =
        Brain.update_page_body(v1, %{body: "See [[B]] only", base_version: 1}, actor: user)

      assert count_links(page.id) == 1

      [link] = list_links(page.id)
      assert link.target_title_at_link_time == "B"
    end
  end

  describe "sources + page_sources" do
    test "upserts Source rows for new URLs in :pending state", %{
      user: user,
      brain: brain,
      page: page
    } do
      body = """
      ```source
      url: https://example.com/article
      ```
      """

      {:ok, _} = Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)

      brain_id_bin = Ecto.UUID.dump!(brain.id)

      sources =
        Repo.all(
          from s in "brain_sources",
            where: s.brain_id == ^brain_id_bin,
            select: %{url: s.url, ingest_status: s.ingest_status}
        )

      assert [%{url: "https://example.com/article", ingest_status: "pending"}] = sources
    end

    test "populates brain_page_sources with document-order position", %{
      user: user,
      page: page
    } do
      body = """
      ```source
      url: https://b.example
      ```

      ```source
      url: https://a.example
      ```
      """

      {:ok, _} = Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)

      sources = list_page_sources(page.id)
      assert length(sources) == 2
      assert [%{position: 0}, %{position: 1}] = sources
    end

    test "reuses existing Source rows for the same (brain, url)", %{
      user: user,
      brain: brain,
      page: page
    } do
      body = """
      ```source
      url: https://reused.example
      ```
      """

      {:ok, v1} = Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)

      brain_id_bin = Ecto.UUID.dump!(brain.id)

      assert 1 ==
               Repo.one(
                 from s in "brain_sources",
                   where: s.brain_id == ^brain_id_bin,
                   select: count(s.id)
               )

      {:ok, _v2} =
        Brain.update_page_body(v1, %{body: body <> "\n\nextra", base_version: 1}, actor: user)

      assert 1 ==
               Repo.one(
                 from s in "brain_sources",
                   where: s.brain_id == ^brain_id_bin,
                   select: count(s.id)
               )
    end
  end

  describe "tags" do
    test "populates page_tags from frontmatter tags list", %{user: user, page: page} do
      body = """
      ---
      tags: [ml, research]
      ---
      body
      """

      {:ok, _} = Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)

      assert [
               %{tag: "ml", source: "frontmatter"},
               %{tag: "research", source: "frontmatter"}
             ] = list_tags(page.id)
    end

    test "populates page_tags from inline #tag occurrences", %{user: user, page: page} do
      {:ok, _} =
        Brain.update_page_body(
          page,
          %{body: "About #ml and #research today", base_version: 0},
          actor: user
        )

      assert [
               %{tag: "ml", source: "inline"},
               %{tag: "research", source: "inline"}
             ] = list_tags(page.id)
    end

    test "frontmatter wins when both sources mention the same tag", %{user: user, page: page} do
      body = """
      ---
      tags: [ml]
      ---
      Note about #ml.
      """

      {:ok, _} = Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)

      assert [%{tag: "ml", source: "frontmatter"}] = list_tags(page.id)
    end
  end

  describe "optimistic locking" do
    test "stale base_version returns a structured VersionConflict error", %{
      user: user,
      page: page
    } do
      {:ok, _v1} = Brain.update_page_body(page, %{body: "first", base_version: 0}, actor: user)

      # `page` is now stale (still at version 0 in the in-memory struct).
      {:error, %Ash.Error.Invalid{errors: errors}} =
        Brain.update_page_body(page, %{body: "second", base_version: 0}, actor: user)

      assert [%VersionConflict{} = conflict | _] = errors
      assert conflict.base_version == 0
      assert conflict.current_version == 1
      assert conflict.current_body == "first"
      assert conflict.current_modified_at != nil
      assert conflict.conflicting_actor_id == user.id
    end

    test "concurrent saves: first wins, second sees conflict with the first's body", %{
      user: user,
      page: page
    } do
      # Both reads see version 0.
      assert {:ok, _winner} =
               Brain.update_page_body(page, %{body: "A", base_version: 0}, actor: user)

      assert {:error, %Ash.Error.Invalid{errors: [%VersionConflict{} = conflict | _]}} =
               Brain.update_page_body(page, %{body: "B", base_version: 0}, actor: user)

      assert conflict.current_body == "A"
      assert conflict.current_version == 1
    end
  end

  describe "workspace file guard" do
    test "rejects bodies referencing files from a different workspace", %{
      user: user,
      page: page
    } do
      other_user = generate(user())
      ensure_workspace_plan(other_user)
      other_ws = generate(workspace(actor: other_user))
      foreign_file = generate(file(actor: other_user, workspace_id: other_ws.id))

      body = "![image](magus://image/#{foreign_file.id})"

      assert {:error, %Ash.Error.Invalid{}} =
               Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)
    end

    test "accepts bodies referencing files in the same (personal) workspace", %{
      user: user,
      page: page
    } do
      ensure_workspace_plan(user)
      same_file = generate(file(actor: user))

      body = "[doc](magus://file/#{same_file.id})"

      assert {:ok, updated} =
               Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)

      assert updated.body == body
    end

    test "rejects bodies referencing files that do not exist", %{user: user, page: page} do
      body = "![image](magus://image/#{Ash.UUID.generate()})"

      assert {:error, %Ash.Error.Invalid{}} =
               Brain.update_page_body(page, %{body: body, base_version: 0}, actor: user)
    end
  end

  describe "paper trail" do
    test "creates a Page.Version row with the body change tracked", %{user: user, page: page} do
      {:ok, _} =
        Brain.update_page_body(page, %{body: "tracked content", base_version: 0}, actor: user)

      require Ash.Query

      versions =
        Magus.Brain.Page.Version
        |> Ash.Query.filter(version_source_id == ^page.id)
        |> Ash.read!(authorize?: false)

      assert length(versions) >= 1

      # Filter by action: the page-create version snapshots a nil body, and
      # when create + update land in the same microsecond, max_by's tie-break
      # can pick it (seen as a CI-only flake).
      latest =
        versions
        |> Enum.filter(&(to_string(&1.version_action_name) == "update_body"))
        |> Enum.max_by(& &1.version_inserted_at)

      # `changes` is the snapshot map. We expect the `body` change to be
      # present (the prior body was nil; the new body is "tracked content").
      assert is_map(latest.changes)
      body_change = latest.changes["body"] || latest.changes[:body]
      assert body_change != nil
    end
  end
end
