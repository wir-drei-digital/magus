defmodule Magus.Agents.Tools.Brain.ReadBrainTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Brain.ReadBrain
  alias Magus.Brain

  import Ecto.Query, only: [from: 2]

  # ---------------------------------------------------------------------------
  # Setup helpers
  # ---------------------------------------------------------------------------

  defp setup_brain(opts \\ []) do
    user = generate(user())

    {:ok, brain} =
      Brain.create_brain(%{title: Keyword.get(opts, :title, "Test Brain")}, actor: user)

    %{user: user, brain: brain}
  end

  defp create_page!(brain_id, title, user, opts \\ []) do
    attrs = %{title: title}

    attrs =
      if pid = Keyword.get(opts, :parent_page_id),
        do: Map.put(attrs, :parent_page_id, pid),
        else: attrs

    {:ok, page} = Brain.create_page(brain_id, attrs, actor: user)
    page
  end

  defp write_body!(page, body, user, base_version \\ 0) do
    {:ok, updated} =
      Brain.update_page_body(page, %{body: body, base_version: base_version}, actor: user)

    updated
  end

  defp default_context(user, brain_id) do
    %{user_id: user.id, user: user, brain_id: brain_id}
  end

  defp context_no_brain(user) do
    %{user_id: user.id, user: user}
  end

  # Backdate a page's updated_at so "stale" can be exercised without time travel.
  # update_body/Ash own the timestamp normally, so we reach past them with a
  # raw update_all on the schemaless table.
  defp backdate_page!(page, days_ago) do
    ts = DateTime.add(DateTime.utc_now(), -days_ago * 86_400, :second)

    {1, _} =
      Magus.Repo.update_all(
        from(p in "brain_pages", where: p.id == type(^page.id, Ecto.UUID)),
        set: [updated_at: ts]
      )

    ts
  end

  # Read-content helpers (read_page / peek_page) — a brain with one page whose
  # id is also seeded into the pane context (brain_page_id) so the pane-fallback
  # path can be exercised.
  defp setup_brain_with_page(body) do
    %{user: user, brain: brain} = setup_brain()
    page = create_page!(brain.id, "Page One", user)
    page = if body == "", do: page, else: write_body!(page, body, user)

    %{
      user: user,
      brain: brain,
      page: page,
      context: %{user_id: user.id, user: user, brain_id: brain.id, brain_page_id: page.id}
    }
  end

  defp context_for(user, brain_id, page_id) do
    %{user_id: user.id, user: user, brain_id: brain_id, brain_page_id: page_id}
  end

  # ---------------------------------------------------------------------------
  # display_name / summarize_output (smoke)
  # ---------------------------------------------------------------------------

  describe "display_name/0 and summarize_output/1" do
    test "provides display name" do
      assert ReadBrain.display_name() =~ "brain"
    end

    test "summarizes list_pages result" do
      assert ReadBrain.summarize_output(%{action: "list_pages", count: 3}) =~ "3"
    end

    test "summarizes search result" do
      assert ReadBrain.summarize_output(%{action: "search", count: 2}) =~ "2"
    end

    test "summarizes empty search" do
      assert ReadBrain.summarize_output(%{action: "search", count: 0}) =~ "No results"
    end

    test "summarizes list_tags result" do
      assert ReadBrain.summarize_output(%{action: "list_tags", count: 5}) =~ "5"
    end

    test "summarizes no backlinks" do
      assert ReadBrain.summarize_output(%{action: "get_backlinks", count: 0}) =~
               "No backlinks"
    end
  end

  # ---------------------------------------------------------------------------
  # list_brains
  # ---------------------------------------------------------------------------

  describe "list_brains action" do
    test "returns the actor's personal brains when no workspace_id in context" do
      user = generate(user())
      {:ok, b1} = Brain.create_brain(%{title: "Personal A"}, actor: user)
      {:ok, b2} = Brain.create_brain(%{title: "Personal B"}, actor: user)

      context = context_no_brain(user)

      assert {:ok, result} = ReadBrain.run(%{"action" => "list_brains"}, context)
      assert result.action == "list_brains"
      assert result.scope == "personal"
      assert result.count == 2

      ids = result.brains |> Enum.map(& &1.brain_id) |> Enum.sort()
      assert ids == Enum.sort([b1.id, b2.id])
    end

    test "isolates by actor — other users' brains are excluded" do
      user_a = generate(user())
      user_b = generate(user())
      {:ok, mine} = Brain.create_brain(%{title: "Mine"}, actor: user_a)
      {:ok, _theirs} = Brain.create_brain(%{title: "Theirs"}, actor: user_b)

      context = context_no_brain(user_a)

      assert {:ok, %{count: 1, brains: [%{brain_id: id}]}} =
               ReadBrain.run(%{"action" => "list_brains"}, context)

      assert id == mine.id
    end

    test "hints at create_brain when scope is empty" do
      user = generate(user())
      context = context_no_brain(user)

      assert {:ok, %{count: 0, hint: hint}} =
               ReadBrain.run(%{"action" => "list_brains"}, context)

      assert hint =~ "create_brain"
    end
  end

  # ---------------------------------------------------------------------------
  # list_pages
  # ---------------------------------------------------------------------------

  describe "list_pages action" do
    setup do
      %{user: user, brain: brain} = setup_brain()
      p1 = create_page!(brain.id, "Page One", user)
      p2 = create_page!(brain.id, "Page Two", user)

      %{
        user: user,
        brain: brain,
        page1: p1,
        page2: p2,
        context: default_context(user, brain.id)
      }
    end

    test "lists all pages in brain", %{context: context} do
      assert {:ok, result} = ReadBrain.run(%{"action" => "list_pages"}, context)
      assert result.action == "list_pages"
      assert result.count == 2
      assert length(result.pages) == 2
    end

    test "returned page entries are summaries with no body", %{context: context} do
      assert {:ok, %{pages: [entry | _]}} =
               ReadBrain.run(%{"action" => "list_pages"}, context)

      assert is_binary(entry.title)
      assert is_binary(entry.page_id)
      assert is_binary(entry.slug)
      assert Map.has_key?(entry, :depth)
      assert Map.has_key?(entry, :position)
      assert Map.has_key?(entry, :has_children?)
      refute Map.has_key?(entry, :body)
    end

    test "auto-discovers brain when not in context", %{user: user} do
      context = context_no_brain(user)

      assert {:ok, result} = ReadBrain.run(%{"action" => "list_pages"}, context)
      assert result.count == 2
    end

    test "includes hint with page count and navigation advice", %{context: context} do
      assert {:ok, result} = ReadBrain.run(%{"action" => "list_pages"}, context)
      assert is_binary(result.hint)
      assert result.hint =~ "2 pages"
      assert result.hint =~ "read_page"
      assert result.hint =~ "find_page"
    end

    test "pages are sorted in depth-first tree order" do
      user = generate(user())
      {:ok, brain} = Brain.create_brain(%{title: "Tree"}, actor: user)
      root = create_page!(brain.id, "Root", user)
      child = create_page!(brain.id, "Child", user, parent_page_id: root.id)
      _grand = create_page!(brain.id, "Grand", user, parent_page_id: child.id)

      context = default_context(user, brain.id)

      assert {:ok, result} = ReadBrain.run(%{"action" => "list_pages"}, context)
      titles = Enum.map(result.pages, & &1.title)
      assert titles == ["Root", "Child", "Grand"]
    end

    test "has_children? is true for parents and false for leaves" do
      user = generate(user())
      {:ok, brain} = Brain.create_brain(%{title: "T"}, actor: user)
      root = create_page!(brain.id, "Root", user)
      _leaf = create_page!(brain.id, "Leaf", user, parent_page_id: root.id)

      context = default_context(user, brain.id)

      assert {:ok, result} = ReadBrain.run(%{"action" => "list_pages"}, context)

      root_entry = Enum.find(result.pages, &(&1.title == "Root"))
      leaf_entry = Enum.find(result.pages, &(&1.title == "Leaf"))

      assert root_entry.has_children? == true
      assert leaf_entry.has_children? == false
    end

    test "returns an indented tree text representation" do
      user = generate(user())
      {:ok, brain} = Brain.create_brain(%{title: "Tree"}, actor: user)
      root = create_page!(brain.id, "Root", user)
      child = create_page!(brain.id, "Child", user, parent_page_id: root.id)
      _grand = create_page!(brain.id, "Grand", user, parent_page_id: child.id)

      context = default_context(user, brain.id)

      assert {:ok, result} = ReadBrain.run(%{"action" => "list_pages"}, context)

      assert result.tree == "- Root\n  - Child\n    - Grand"
    end

    test "root_only returns only root pages", %{
      context: context,
      brain: brain,
      user: user,
      page1: parent
    } do
      _child = create_page!(brain.id, "Sub", user, parent_page_id: parent.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_pages", "root_only" => true}, context)

      assert result.count >= 1
      Enum.each(result.pages, fn p -> assert p.parent_page_id == nil end)
    end

    test "parent_page_id filters to children", %{
      context: context,
      brain: brain,
      user: user,
      page1: parent
    } do
      child = create_page!(brain.id, "Only Child", user, parent_page_id: parent.id)
      _other = create_page!(brain.id, "Other Root", user)

      assert {:ok, result} =
               ReadBrain.run(
                 %{"action" => "list_pages", "parent_page_id" => parent.id},
                 context
               )

      assert result.count == 1
      assert hd(result.pages).page_id == child.id
    end
  end

  # ---------------------------------------------------------------------------
  # list_pages: tag filter
  # ---------------------------------------------------------------------------

  describe "list_pages with tag filter" do
    setup do
      %{user: user, brain: brain} = setup_brain()
      tagged = create_page!(brain.id, "Tagged", user)
      untagged = create_page!(brain.id, "Untagged", user)

      write_body!(tagged, "---\ntags: [ml, research]\n---\nbody\n", user)
      write_body!(untagged, "plain body, no tags", user)

      %{
        user: user,
        brain: brain,
        tagged: tagged,
        untagged: untagged,
        context: default_context(user, brain.id)
      }
    end

    test "single tag string filters to pages carrying that tag", %{
      context: context,
      tagged: tagged
    } do
      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_pages", "tag" => "ml"}, context)

      assert result.count == 1
      assert hd(result.pages).page_id == tagged.id
    end

    test "list of tags requires every tag (AND, not OR)", %{
      context: context,
      tagged: tagged
    } do
      assert {:ok, result} =
               ReadBrain.run(
                 %{"action" => "list_pages", "tag" => ["ml", "research"]},
                 context
               )

      assert result.count == 1
      assert hd(result.pages).page_id == tagged.id

      assert {:ok, none} =
               ReadBrain.run(
                 %{"action" => "list_pages", "tag" => ["ml", "nope-not-present"]},
                 context
               )

      assert none.count == 0
    end

    test "tag normalization handles whitespace and case", %{
      context: context,
      tagged: tagged
    } do
      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_pages", "tag" => "ML"}, context)

      assert result.count == 1
      assert hd(result.pages).page_id == tagged.id
    end
  end

  # ---------------------------------------------------------------------------
  # find_page
  # ---------------------------------------------------------------------------

  describe "find_page action" do
    setup do
      %{user: user, brain: brain} = setup_brain()
      elixir_page = create_page!(brain.id, "Elixir Notes", user)
      ruby_page = create_page!(brain.id, "Ruby Notes", user)
      ash_page = create_page!(brain.id, "Frameworks", user)

      write_body!(elixir_page, "# Elixir\n\nFunctional programming.", user)
      write_body!(ruby_page, "# Ruby\n\nDynamic, OO.", user)
      write_body!(ash_page, "# Frameworks\n\nPhoenix and Ash use Elixir.", user)

      %{
        user: user,
        brain: brain,
        elixir_page: elixir_page,
        ruby_page: ruby_page,
        ash_page: ash_page,
        context: default_context(user, brain.id)
      }
    end

    test "returns error when query is missing", %{context: context} do
      assert {:ok, %{error: error}} = ReadBrain.run(%{"action" => "find_page"}, context)
      assert error =~ "query"
    end

    test "resolves the brain by title passed in the brain_id param", %{
      user: user,
      brain: brain,
      elixir_page: elixir
    } do
      # No brain in context — the explicit `brain_id` is the brain's *title*.
      ctx = context_no_brain(user)

      assert {:ok, result} =
               ReadBrain.run(
                 %{"action" => "find_page", "query" => "Elixir Notes", "brain_id" => brain.title},
                 ctx
               )

      assert result.action == "find_page"
      assert Enum.any?(result.pages, &(&1.page_id == elixir.id))
    end

    test "exact title match outranks body match", %{
      context: context,
      elixir_page: elixir,
      ash_page: ash
    } do
      assert {:ok, result} =
               ReadBrain.run(%{"action" => "find_page", "query" => "Elixir Notes"}, context)

      assert result.action == "find_page"
      assert result.count >= 1

      first = hd(result.pages)
      assert first.page_id == elixir.id

      # Body-only match ranks lower; both pages are present, but elixir is first.
      ranks = Enum.map(result.pages, & &1.page_id)

      assert Enum.find_index(ranks, &(&1 == elixir.id)) <
               (Enum.find_index(ranks, &(&1 == ash.id)) || 999)
    end

    test "title substring match returns the right page", %{
      context: context,
      elixir_page: elixir
    } do
      assert {:ok, result} =
               ReadBrain.run(%{"action" => "find_page", "query" => "elixir"}, context)

      ids = Enum.map(result.pages, & &1.page_id)
      assert elixir.id in ids
    end

    test "body FTS finds the page even when title does not match", %{
      context: context,
      ash_page: ash
    } do
      assert {:ok, result} =
               ReadBrain.run(%{"action" => "find_page", "query" => "Phoenix"}, context)

      ids = Enum.map(result.pages, & &1.page_id)
      assert ash.id in ids
    end

    test "returns no results and a create-hint for missing query", %{context: context} do
      assert {:ok, result} =
               ReadBrain.run(
                 %{"action" => "find_page", "query" => "zzz_totally_nonexistent_zzz"},
                 context
               )

      assert result.count == 0
      assert result.pages == []
      assert result.hint =~ "new title to create a page"
    end

    test "result entries carry the expected shape", %{
      context: context
    } do
      assert {:ok, %{pages: [entry | _]}} =
               ReadBrain.run(%{"action" => "find_page", "query" => "Elixir"}, context)

      assert Map.has_key?(entry, :page_id)
      assert Map.has_key?(entry, :title)
      assert Map.has_key?(entry, :brain_id)
      assert Map.has_key?(entry, :brain_title)
      assert Map.has_key?(entry, :snippet)
      assert Map.has_key?(entry, :score)
    end

    test "scopes to specified brain_id", %{user: user, context: context, brain: brain} do
      {:ok, other_brain} = Brain.create_brain(%{title: "Other"}, actor: user)
      other_page = create_page!(other_brain.id, "Elixir Tips", user)
      write_body!(other_page, "Body about Elixir.", user)

      assert {:ok, result} =
               ReadBrain.run(
                 %{"action" => "find_page", "query" => "Elixir", "brain_id" => brain.id},
                 context
               )

      assert result.count >= 1
      Enum.each(result.pages, fn p -> assert p.brain_id == brain.id end)
    end

    test "brain_id: nil searches every accessible brain (cross-brain)", %{
      user: user,
      brain: brain
    } do
      {:ok, other_brain} = Brain.create_brain(%{title: "Other"}, actor: user)
      other_page = create_page!(other_brain.id, "Elixir Tips", user)
      write_body!(other_page, "Body about Elixir.", user)

      context = context_no_brain(user)

      assert {:ok, result} =
               ReadBrain.run(
                 %{"action" => "find_page", "query" => "Elixir", "brain_id" => nil},
                 context
               )

      brain_ids = result.pages |> Enum.map(& &1.brain_id) |> Enum.uniq() |> Enum.sort()
      assert brain.id in brain_ids
      assert other_brain.id in brain_ids
    end

    test "tags boost moves matching pages up", %{
      user: user,
      brain: brain
    } do
      # Two pages with body mentioning "Phoenix"; only one carries the tag.
      tagged = create_page!(brain.id, "Tagged Phoenix Notes", user)
      untagged = create_page!(brain.id, "Untagged Phoenix Notes", user)

      write_body!(
        tagged,
        "---\ntags: [phoenix]\n---\nLong essay about Phoenix and the BEAM.",
        user
      )

      write_body!(untagged, "Long essay about Phoenix and the BEAM.", user)

      context = default_context(user, brain.id)

      assert {:ok, %{pages: ranked}} =
               ReadBrain.run(
                 %{"action" => "find_page", "query" => "Phoenix", "tags" => ["phoenix"]},
                 context
               )

      ids = Enum.map(ranked, & &1.page_id)

      assert Enum.find_index(ids, &(&1 == tagged.id)) <
               (Enum.find_index(ids, &(&1 == untagged.id)) || 999)
    end
  end

  # ---------------------------------------------------------------------------
  # search (semantic, PageChunk + SourceChunk)
  # ---------------------------------------------------------------------------

  describe "search action" do
    test "returns error for missing query" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, %{error: error}} = ReadBrain.run(%{"action" => "search"}, context)
      assert error =~ "query"
    end

    # The embedding API is unavailable in the test environment. We exercise
    # the dispatch and verify it returns the unavailable-shape rather than
    # crashing or emitting noise. Live semantic search is covered by the
    # e2e-live suite plus the Brain.search_page_chunks unit tests.
    test "returns an embedding-unavailable hint when the embed API is down" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "P", user)
      write_body!(page, "Body about Elixir and Phoenix.", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "search", "query" => "Elixir"}, context)

      assert result.action == "search"
      assert is_integer(result.count)
      assert is_list(result.results)
      assert result.kind == "all"
      assert is_binary(result.hint)
    end

    test "honors kind filter values", %{} do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, pages_result} =
               ReadBrain.run(
                 %{"action" => "search", "query" => "anything", "kind" => "pages"},
                 context
               )

      assert pages_result.kind == "pages"

      assert {:ok, sources_result} =
               ReadBrain.run(
                 %{"action" => "search", "query" => "anything", "kind" => "sources"},
                 context
               )

      assert sources_result.kind == "sources"

      # Unknown kind falls back to :all rather than failing.
      assert {:ok, fallback} =
               ReadBrain.run(
                 %{"action" => "search", "query" => "anything", "kind" => "weird"},
                 context
               )

      assert fallback.kind == "all"
    end

    test "respects limit param" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(
                 %{"action" => "search", "query" => "anything", "limit" => 3},
                 context
               )

      assert length(result.results) <= 3
    end

    test "cross-brain search when brain_id is nil does not crash" do
      user = generate(user())
      {:ok, _b1} = Brain.create_brain(%{title: "One"}, actor: user)
      {:ok, _b2} = Brain.create_brain(%{title: "Two"}, actor: user)

      context = context_no_brain(user)

      assert {:ok, result} =
               ReadBrain.run(
                 %{"action" => "search", "query" => "anything", "brain_id" => nil},
                 context
               )

      assert result.action == "search"
      assert is_list(result.results)
    end
  end

  # ---------------------------------------------------------------------------
  # get_backlinks (via brain_page_links)
  # ---------------------------------------------------------------------------

  describe "get_backlinks action" do
    setup do
      %{user: user, brain: brain} = setup_brain()
      target = create_page!(brain.id, "Target", user)
      _empty = write_body!(target, "Target body.", user)
      linker_a = create_page!(brain.id, "Linker A", user)
      linker_b = create_page!(brain.id, "Linker B", user)
      write_body!(linker_a, "See [[Target]] for details.", user)
      write_body!(linker_b, "More about [[Target]] is here.", user)

      %{
        user: user,
        brain: brain,
        target: target,
        linker_a: linker_a,
        linker_b: linker_b,
        context: default_context(user, brain.id)
      }
    end

    test "returns linking pages and their titles", %{
      context: context,
      target: target,
      linker_a: linker_a,
      linker_b: linker_b
    } do
      assert {:ok, result} =
               ReadBrain.run(
                 %{"action" => "get_backlinks", "page_id" => target.id},
                 context
               )

      assert result.action == "get_backlinks"
      assert result.count == 2

      ids = result.backlinks |> Enum.map(& &1.source_page_id) |> Enum.sort()
      assert ids == Enum.sort([linker_a.id, linker_b.id])
    end

    test "carries target_title_at_link_time for rename-drift detection", %{
      context: context,
      target: target
    } do
      assert {:ok, %{backlinks: [bl | _]}} =
               ReadBrain.run(
                 %{"action" => "get_backlinks", "page_id" => target.id},
                 context
               )

      assert bl.target_title_at_link_time == "Target"
    end

    test "missing page_id returns an error", %{context: context} do
      assert {:ok, %{error: error}} = ReadBrain.run(%{"action" => "get_backlinks"}, context)
      assert error =~ "page_id"
    end

    test "returns empty list with a helpful hint when no pages link", %{
      user: user,
      brain: brain
    } do
      lonely = create_page!(brain.id, "Lonely", user)
      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(
                 %{"action" => "get_backlinks", "page_id" => lonely.id},
                 context
               )

      assert result.count == 0
      assert result.backlinks == []
      assert result.hint =~ "[[Page Name]]"
    end
  end

  # ---------------------------------------------------------------------------
  # list_tags
  # ---------------------------------------------------------------------------

  describe "list_tags action" do
    setup do
      %{user: user, brain: brain} = setup_brain()
      p1 = create_page!(brain.id, "One", user)
      p2 = create_page!(brain.id, "Two", user)
      write_body!(p1, "---\ntags: [ml, research]\n---\nbody one", user)
      write_body!(p2, "---\ntags: [ml]\n---\nbody two", user)

      %{
        user: user,
        brain: brain,
        context: default_context(user, brain.id)
      }
    end

    test "returns per-tag page counts for a single brain", %{context: context} do
      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_tags"}, context)

      assert result.action == "list_tags"
      tags = Map.new(result.tags, &{&1.tag, &1.count})
      assert tags["ml"] == 2
      assert tags["research"] == 1
    end

    test "cross-brain when brain_id is nil", %{user: user, brain: brain} do
      {:ok, other_brain} = Brain.create_brain(%{title: "Other"}, actor: user)
      op = create_page!(other_brain.id, "OP", user)
      write_body!(op, "---\ntags: [history]\n---\nbody", user)

      context = context_no_brain(user)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_tags", "brain_id" => nil}, context)

      tag_strings = result.tags |> Enum.map(& &1.tag) |> Enum.uniq() |> Enum.sort()
      assert "ml" in tag_strings
      assert "history" in tag_strings

      brain_ids = result.tags |> Enum.map(& &1.brain_id) |> Enum.uniq() |> Enum.sort()
      assert brain.id in brain_ids
      assert other_brain.id in brain_ids
    end

    test "empty brain returns an empty tag list", %{user: user} do
      {:ok, empty_brain} = Brain.create_brain(%{title: "Empty"}, actor: user)
      context = default_context(user, empty_brain.id)

      assert {:ok, result} = ReadBrain.run(%{"action" => "list_tags"}, context)
      assert result.count == 0
      assert result.tags == []
    end
  end

  # ---------------------------------------------------------------------------
  # File references in body (replaces the previous block-shaped test)
  # ---------------------------------------------------------------------------

  describe "file references in page body" do
    setup do
      user = generate(user()) |> ensure_workspace_plan()
      {:ok, brain} = Brain.create_brain(%{title: "FileBrain"}, actor: user)
      page = create_page!(brain.id, "FilePage", user)

      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1024,
            file_path: "tmp/doc.pdf",
            workspace_id: nil
          },
          actor: user
        )

      body = "# FilePage\n\n[📎 spec](magus://file/#{file.id})\n"
      write_body!(page, body, user)

      %{
        user: user,
        brain: brain,
        page: page,
        attached_file: file,
        context: default_context(user, brain.id)
      }
    end

    test "find_page surfaces pages whose body links a file via magus:// URL", %{
      context: context,
      page: page
    } do
      assert {:ok, %{pages: pages}} =
               ReadBrain.run(%{"action" => "find_page", "query" => "spec"}, context)

      ids = Enum.map(pages, & &1.page_id)
      assert page.id in ids
    end

    test "list_pages includes the file-referencing page", %{
      context: context,
      page: page
    } do
      assert {:ok, %{pages: pages}} =
               ReadBrain.run(%{"action" => "list_pages"}, context)

      ids = Enum.map(pages, & &1.page_id)
      assert page.id in ids
    end
  end

  # ---------------------------------------------------------------------------
  # error handling
  # ---------------------------------------------------------------------------

  describe "error handling" do
    test "returns error for invalid action" do
      user = generate(user())
      context = context_no_brain(user)
      assert {:ok, %{error: error}} = ReadBrain.run(%{"action" => "nope"}, context)
      assert error =~ "Unknown action"
    end

    test "returns error for missing action" do
      user = generate(user())
      context = context_no_brain(user)
      assert {:ok, %{error: error}} = ReadBrain.run(%{}, context)
      assert error =~ "action"
    end

    test "returns error when context missing" do
      assert {:ok, %{error: _}} = ReadBrain.run(%{"action" => "list_pages"}, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # list_curation_candidates
  # ---------------------------------------------------------------------------

  describe "list_curation_candidates action" do
    test "drifted: flags a parent whose child changed after it" do
      %{user: user, brain: brain} = setup_brain()
      parent = create_page!(brain.id, "Index", user)
      child = create_page!(brain.id, "Child", user, parent_page_id: parent.id)
      # Parent created first; touch the child last so child.updated_at > parent.updated_at.
      write_body!(child, "child content", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      assert result.action == "list_curation_candidates"
      assert parent.id in Enum.map(result.drifted, & &1.page_id)

      entry = Enum.find(result.drifted, &(&1.page_id == parent.id))
      assert child.id in Enum.map(entry.changed_children, & &1.page_id)
    end

    test "drifted: does NOT flag a parent edited after its child" do
      %{user: user, brain: brain} = setup_brain()
      parent = create_page!(brain.id, "Index", user)
      child = create_page!(brain.id, "Child", user, parent_page_id: parent.id)
      write_body!(child, "child content", user)
      # Update the parent last → parent.updated_at > child.updated_at.
      write_body!(parent, "fresh rollup", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      refute parent.id in Enum.map(result.drifted, & &1.page_id)
    end

    test "orphans: flags pages with no inbound wikilinks" do
      %{user: user, brain: brain} = setup_brain()
      target = create_page!(brain.id, "Linked", user)
      linker = create_page!(brain.id, "Linker", user)
      write_body!(linker, "see [[Linked]]", user)
      lonely = create_page!(brain.id, "Lonely", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      orphan_ids = Enum.map(result.orphans, & &1.page_id)
      assert lonely.id in orphan_ids
      assert linker.id in orphan_ids
      refute target.id in orphan_ids
    end

    test "stale: flags pages past the window and respects stale_after_days" do
      %{user: user, brain: brain} = setup_brain()
      old = create_page!(brain.id, "Old", user)
      _fresh = create_page!(brain.id, "Fresh", user)
      backdate_page!(old, 100)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      assert old.id in Enum.map(result.stale, & &1.page_id)
      stale_entry = Enum.find(result.stale, &(&1.page_id == old.id))
      assert stale_entry.days_since >= 99

      # Widen the window past the backdate → nothing stale.
      assert {:ok, none} =
               ReadBrain.run(
                 %{"action" => "list_curation_candidates", "stale_after_days" => 365},
                 context
               )

      refute old.id in Enum.map(none.stale, & &1.page_id)
    end

    test "recently_changed surfaces a just-edited page; counts and count present" do
      %{user: user, brain: brain} = setup_brain()
      p = create_page!(brain.id, "Recent", user)
      write_body!(p, "just now", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      assert p.id in Enum.map(result.recently_changed, & &1.page_id)
      assert is_integer(result.count)
      assert Map.has_key?(result.counts, :drifted)
    end

    test "entries carry no page body (metadata only)" do
      %{user: user, brain: brain} = setup_brain()
      p = create_page!(brain.id, "P", user)
      write_body!(p, "secret body text", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      entries =
        result.drifted ++ result.stale ++ result.orphans ++ result.recently_changed

      Enum.each(entries, fn e -> refute Map.has_key?(e, :body) end)
    end

    test "count is the deduped union of actionable signals (a page counts once)" do
      %{user: user, brain: brain} = setup_brain()
      # A lone root page with no children and no inbound links, backdated:
      # it is BOTH stale and an orphan, but must contribute 1 to count.
      page = create_page!(brain.id, "Solo", user)
      backdate_page!(page, 100)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      assert page.id in Enum.map(result.stale, & &1.page_id)
      assert page.id in Enum.map(result.orphans, & &1.page_id)
      assert result.count == 1
    end

    test "empty brain returns zeroed counts" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      assert result.count == 0
      assert result.counts.drifted == 0
      assert result.recently_changed == []
    end
  end

  # ---------------------------------------------------------------------------
  # read_page
  # ---------------------------------------------------------------------------

  describe "read_page action" do
    test "returns the body, line_count, breadcrumb, frontmatter and current" do
      %{context: ctx, page: page, brain: brain} =
        setup_brain_with_page("# Title\n\nSome body content.")

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "read_page", "page_id" => page.id}, ctx)

      assert result.action == "read_page"
      assert result.page_id == page.id
      assert result.page_title == page.title
      assert result.body =~ "Some body content"
      assert is_integer(result.line_count)
      assert is_binary(result.breadcrumb)
      assert is_map(result.frontmatter)
      assert result.current.brain_id == brain.id
      assert result.current.page_id == page.id
    end

    test "carries the brain's Guide with the result (just-in-time steering)" do
      %{context: ctx, page: page, brain: brain, user: user} =
        setup_brain_with_page("# Title\n\nBody.")

      {:ok, _} =
        Brain.set_brain_instructions(brain, %{instructions: "One concept per page."}, actor: user)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "read_page", "page_id" => page.id}, ctx)

      # Pure-tool flows have no companion/pane injection, so opening a page
      # surfaces its location's Guide with the result.
      assert result.guide =~ "### Brain Guide"
      assert result.guide =~ "One concept per page."
    end

    test "omits the guide key when the brain has no Guide" do
      %{context: ctx, page: page} = setup_brain_with_page("# Title\n\nBody.")

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "read_page", "page_id" => page.id}, ctx)

      refute Map.has_key?(result, :guide)
    end

    test "a blank page_id is treated as absent and falls back to the pane page" do
      %{context: ctx, page: page} = setup_brain_with_page("# Title\n\nSome body content.")

      # LLMs send page_id: "" for "no page id"; it used to reach
      # Brain.get_page("") and raise InvalidFilterValue with a query dump.
      assert {:ok, result} =
               ReadBrain.run(%{"action" => "read_page", "page_id" => ""}, ctx)

      refute Map.has_key?(result, :error)
      assert result.page_id == page.id
    end

    test "supports start_line / end_line slicing with line-number prefixes" do
      body = Enum.map_join(1..6, "\n", fn i -> "line #{i}" end)
      %{context: ctx, page: page} = setup_brain_with_page(body)

      assert {:ok, result} =
               ReadBrain.run(
                 %{
                   "action" => "read_page",
                   "page_id" => page.id,
                   "start_line" => 2,
                   "end_line" => 4
                 },
                 ctx
               )

      assert result.body =~ "2: line 2"
      assert result.body =~ "3: line 3"
      assert result.body =~ "4: line 4"
      refute result.body =~ "1: line 1"
      refute result.body =~ "5: line 5"
    end

    test "errors helpfully when start_line is out of range" do
      %{context: ctx, page: page} = setup_brain_with_page("one\ntwo")

      assert {:ok, result} =
               ReadBrain.run(
                 %{
                   "action" => "read_page",
                   "page_id" => page.id,
                   "start_line" => 50,
                   "end_line" => 60
                 },
                 ctx
               )

      assert result.body =~ "exceeds" or result.body =~ "start_line"
    end

    test "falls back to the page in the brain pane when neither page_id nor page_title provided" do
      %{context: ctx, page: page} = setup_brain_with_page("In the pane")

      assert {:ok, result} = ReadBrain.run(%{"action" => "read_page"}, ctx)
      assert result.page_id == page.id
      assert result.body =~ "In the pane"
    end

    test "returns an error when the page can't be resolved" do
      %{user: user, brain: brain} = setup_brain()
      ctx = %{user_id: user.id, user: user, brain_id: brain.id}

      assert {:ok, %{error: error}} =
               ReadBrain.run(
                 %{"action" => "read_page", "page_title" => "does not exist"},
                 ctx
               )

      assert error =~ "not found" or error =~ "Page"
    end

    test "hints when the body is empty" do
      %{context: ctx, page: page} = setup_brain_with_page("")

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "read_page", "page_id" => page.id}, ctx)

      assert Map.get(result, :hint, "") =~ "empty" or Map.get(result, :body) == ""
    end
  end

  # ---------------------------------------------------------------------------
  # peek_page
  # ---------------------------------------------------------------------------

  describe "peek_page action" do
    test "returns title + first_200_chars + line_count + last_modified_at + current" do
      body = String.duplicate("abcdefghij", 30)
      %{context: ctx, page: page, brain: brain} = setup_brain_with_page(body)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "peek_page", "page_id" => page.id}, ctx)

      assert result.action == "peek_page"
      assert result.page_id == page.id
      assert result.page_title == page.title
      assert byte_size(result.first_200_chars) <= 200
      assert is_integer(result.line_count)
      assert result.last_modified_at
      assert result.current.brain_id == brain.id
      assert result.current.page_id == page.id
    end

    test "errors when page is missing" do
      %{user: user, brain: brain} = setup_brain()
      ctx = %{user_id: user.id, user: user, brain_id: brain.id}

      assert {:ok, %{error: _}} =
               ReadBrain.run(
                 %{"action" => "peek_page", "page_title" => "Nope"},
                 ctx
               )
    end
  end

  # ---------------------------------------------------------------------------
  # read_source
  # ---------------------------------------------------------------------------

  describe "read_source action" do
    test "returns ingested source content when looked up by source_id" do
      %{user: user, brain: brain} = setup_brain()
      ctx = context_for(user, brain.id, nil)

      {:ok, source} =
        Magus.Brain.Source
        |> Ash.Changeset.for_create(:create, %{
          brain_id: brain.id,
          url: "https://example.com/post"
        })
        |> Ash.create(authorize?: false)

      assert {:ok, result} =
               ReadBrain.run(
                 %{"action" => "read_source", "source_id" => source.id},
                 ctx
               )

      assert result.action == "read_source"
      assert result.source_id == source.id
      assert result.url == "https://example.com/post"
      assert Map.has_key?(result, :ingest_status)
    end

    test "errors when neither source_id nor url is provided" do
      %{user: user, brain: brain} = setup_brain()
      ctx = context_for(user, brain.id, nil)

      assert {:ok, %{error: error}} = ReadBrain.run(%{"action" => "read_source"}, ctx)
      assert error =~ "source_id" or error =~ "url"
    end
  end
end
