defmodule Magus.Agents.Context.BrainContextTest do
  use Magus.DataCase, async: true

  import Ecto.Query
  import Magus.Generators

  alias Magus.Agents.Context.BrainContext
  alias Magus.Brain
  alias Magus.Repo

  setup do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "LLM Research"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "Scaling Laws"}, actor: user)

    set_page_fields(page.id,
      body: """
      # Scaling Laws

      Power law scaling is fundamental.

      See [[Training Data]] for related notes.

      #important #ml
      """
    )

    %{user: user, brain: brain, page: page}
  end

  defp set_page_fields(page_id, fields) do
    page_id_bin = Ecto.UUID.dump!(page_id)

    fields = Keyword.put(fields, :updated_at, DateTime.utc_now())

    {1, _} =
      from(p in "brain_pages", where: p.id == ^page_id_bin)
      |> Repo.update_all(set: fields)

    :ok
  end

  describe "build/3" do
    test "returns nil when no brain_id provided" do
      assert BrainContext.build(nil, nil) == nil
    end

    test "returns nil when no page_id provided", %{brain: brain} do
      assert BrainContext.build(brain.id, nil) == nil
    end

    test "returns nil for nonexistent brain_id" do
      assert BrainContext.build(Ecto.UUID.generate(), Ecto.UUID.generate()) == nil
    end

    test "includes the page body preview", %{user: user, brain: brain, page: page} do
      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context != nil
      assert context =~ "LLM Research"
      assert context =~ "Scaling Laws"
      assert context =~ "Power law scaling is fundamental"
    end

    test "includes brain metadata", %{user: user, brain: brain, page: page} do
      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "Brain:"
      assert context =~ "Current Page:"
    end

    test "surfaces the available brains list in the pane context", %{
      user: user,
      brain: brain,
      page: page
    } do
      context = BrainContext.build(brain.id, page.id, actor: user, workspace_id: nil)
      assert context =~ "### Available brains"
      assert context =~ brain.id
    end

    test "marks the active page in page list", %{user: user, brain: brain, page: page} do
      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "Scaling Laws [ACTIVE]"
    end

    test "includes brain description when present", %{user: user} do
      {:ok, brain} =
        Brain.create_brain(
          %{title: "AI Notes", description: "Notes on artificial intelligence"},
          actor: user
        )

      {:ok, page} = Brain.create_page(brain.id, %{title: "Overview"}, actor: user)
      set_page_fields(page.id, body: "Some overview text.")

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "Notes on artificial intelligence"
    end

    test "lists multiple pages", %{user: user, brain: brain, page: page} do
      {:ok, _page2} = Brain.create_page(brain.id, %{title: "Training Data"}, actor: user)

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "Scaling Laws [ACTIVE]"
      assert context =~ "Training Data"
      refute context =~ "Training Data [ACTIVE]"
    end
  end

  describe "stats" do
    test "counts pages, lines, sources, wikilinks, and tags", %{
      user: user,
      brain: brain,
      page: page
    } do
      {:ok, _} = Brain.create_page(brain.id, %{title: "Training Data"}, actor: user)

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "Stats:"
      assert context =~ "pages"
      assert context =~ "lines"
      assert context =~ "sources"
      assert context =~ "wikilinks"
      assert context =~ "tags"
    end

    test "counts source URLs from fenced source blocks", %{user: user, brain: brain, page: page} do
      set_page_fields(page.id,
        body: """
        # Page

        ```source
        url: https://wikipedia.org
        title: Wikipedia
        ```

        ```source
        url: https://example.com
        title: Example
        ```
        """
      )

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "2 sources"
    end

    test "counts wikilinks in the body", %{user: user, brain: brain, page: page} do
      set_page_fields(page.id,
        body: "See [[Other Page]] and [[Yet Another]] but not [[msg:abc]]"
      )

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "2 wikilinks"
    end

    test "tag count merges inline tags and frontmatter tags uniquely", %{
      user: user,
      brain: brain,
      page: page
    } do
      set_page_fields(page.id,
        body: "Body with #ml and #ai inline.",
        frontmatter: %{"tags" => ["ml", "research"]}
      )

      # ml is shared between inline and frontmatter, so total distinct = 3
      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "3 tags"
    end
  end

  describe "sources section" do
    test "lists source URLs found in the body", %{user: user, brain: brain, page: page} do
      set_page_fields(page.id,
        body: """
        # Page

        ```source
        url: https://wikipedia.org
        title: Wikipedia
        ```
        """
      )

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "### Sources referenced"
      assert context =~ "- https://wikipedia.org"
    end

    test "omits sources section entirely when none are referenced", %{
      user: user,
      brain: brain,
      page: page
    } do
      set_page_fields(page.id, body: "# Hello\n\nNo sources here.")

      context = BrainContext.build(brain.id, page.id, actor: user)
      refute context =~ "Sources referenced"
    end
  end

  describe "frontmatter" do
    test "surfaces icon from cached frontmatter", %{user: user, brain: brain, page: page} do
      set_page_fields(page.id,
        body: "# Hello",
        frontmatter: %{"icon" => "🧠"}
      )

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "Frontmatter:"
      assert context =~ "icon 🧠"
    end

    test "surfaces tags from cached frontmatter as #tag list", %{
      user: user,
      brain: brain,
      page: page
    } do
      set_page_fields(page.id,
        body: "# Hello",
        frontmatter: %{"tags" => ["ml", "research"]}
      )

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "Frontmatter:"
      assert context =~ "tags:"
      assert context =~ "#ml"
      assert context =~ "#research"
    end

    test "falls back to parsing frontmatter from the body when cache is empty", %{
      user: user,
      brain: brain,
      page: page
    } do
      set_page_fields(page.id,
        body: """
        ---
        icon: 📚
        tags: [literature]
        ---

        # Hello
        """,
        frontmatter: %{}
      )

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "icon 📚"
      assert context =~ "#literature"
    end

    test "strips frontmatter from the body preview", %{user: user, brain: brain, page: page} do
      set_page_fields(page.id,
        body: """
        ---
        icon: 🧠
        tags: [ml]
        ---

        # Real Content

        The actual body text.
        """,
        frontmatter: %{"icon" => "🧠", "tags" => ["ml"]}
      )

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "Real Content"
      assert context =~ "The actual body text"
      # The raw `---` frontmatter delimiter must not bleed into the body preview.
      refute context =~ "tags: [ml]"
    end

    test "omits the frontmatter line when no known fields are present", %{
      user: user,
      brain: brain,
      page: page
    } do
      set_page_fields(page.id, body: "# Hello\n\nBody.", frontmatter: %{})

      context = BrainContext.build(brain.id, page.id, actor: user)
      refute context =~ "Frontmatter:"
    end
  end

  describe "body preview" do
    test "truncates long bodies with an ellipsis", %{user: user, brain: brain, page: page} do
      long_body = String.duplicate("abcdefghij", 100)
      set_page_fields(page.id, body: long_body)

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "…"
      # The 1000-char body must NOT appear verbatim in the rendered context;
      # only the leading slice + ellipsis should.
      refute context =~ long_body
      assert context =~ String.slice(long_body, 0, 500) <> "…"
    end

    test "does not truncate short bodies", %{user: user, brain: brain, page: page} do
      short_body = "# Short page\n\nJust a few words."
      set_page_fields(page.id, body: short_body)

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "Just a few words."
      refute context =~ "…"
    end

    test "renders an empty-page placeholder when body is empty", %{
      user: user,
      brain: brain,
      page: page
    } do
      set_page_fields(page.id, body: "")

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "_(empty page)_"
    end

    test "renders an empty-page placeholder when body is nil", %{
      user: user,
      brain: brain,
      page: page
    } do
      # body defaults to nil; clear it explicitly to be unambiguous.
      set_page_fields(page.id, body: nil)

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context != nil
      assert context =~ "_(empty page)_"
    end
  end

  describe "available_brains_section/2" do
    test "lists the actor's brains with ids", %{user: user, brain: brain} do
      section = BrainContext.available_brains_section(user, nil)
      assert section =~ "### Available brains"
      assert section =~ brain.title
      assert section =~ brain.id
    end

    test "returns nil when the actor has no brains" do
      other = generate(user())
      # other user owns no brains in this scope
      assert BrainContext.available_brains_section(other, nil) == nil
    end
  end

  describe "full_tree/2" do
    test "renders nested indentation with ids and marks the active page", %{
      user: user,
      brain: brain
    } do
      {:ok, parent} = Brain.create_page(brain.id, %{title: "Parent"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: parent.id}, actor: user)

      {:ok, pages} = Brain.list_pages(brain.id, actor: user)

      tree = BrainContext.full_tree(pages, child.id)

      assert tree =~ "- Parent (id: #{parent.id})"
      # Child is indented under parent and carries the [THIS PAGE] marker
      assert tree =~ ~r/\n  - Child \[THIS PAGE\] \(id: #{child.id}\)/
      refute tree =~ "Parent [THIS PAGE]"
    end

    test "caps the tree and appends a truncation note past the max" do
      # @max_tree_pages is 400; generate more than that to trigger the cap.
      pages =
        for i <- 1..410 do
          %{id: Ecto.UUID.generate(), title: "Page #{i}", parent_page_id: nil, position: i * 1.0}
        end

      [first | _] = pages
      tree = BrainContext.full_tree(pages, first.id)

      assert tree =~ "more pages"
      assert tree =~ "read_brain.list_pages"
      # The active page (first) is within the cap, so it should still be marked.
      assert tree =~ "[THIS PAGE]"
    end
  end

  describe "Brain Guide section" do
    test "includes the constitution when brain.instructions is set", %{user: user, brain: brain} do
      {:ok, _brain} =
        Brain.set_brain_instructions(brain, %{instructions: "Always cite sources."}, actor: user)

      {:ok, page} = Brain.create_page(brain.id, %{title: "Overview"}, actor: user)
      set_page_fields(page.id, body: "# Overview")

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "### Brain Guide"
      assert context =~ "Always cite sources."
    end

    test "includes inherited section guides ordered root-to-current", %{
      user: user,
      brain: brain
    } do
      {:ok, root} = Brain.create_page(brain.id, %{title: "Root"}, actor: user)

      set_page_fields(root.id,
        body: "# Root",
        frontmatter: %{"instructions" => "Root-level guidance."}
      )

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: root.id}, actor: user)

      set_page_fields(child.id,
        body: "# Child",
        frontmatter: %{"instructions" => "Child-level guidance."}
      )

      context = BrainContext.build(brain.id, child.id, actor: user)
      assert context =~ "### Brain Guide"
      assert context =~ "Root-level guidance."
      assert context =~ "Child-level guidance."

      # Root's guide must appear before Child's guide (root-to-current order).
      root_index = :binary.match(context, "Root-level guidance.") |> elem(0)
      child_index = :binary.match(context, "Child-level guidance.") |> elem(0)
      assert root_index < child_index
    end

    test "includes a Types line listing template titles", %{user: user, brain: brain} do
      {:ok, template} =
        Brain.create_page(brain.id, %{title: "Meeting Note", kind: :template}, actor: user)

      set_page_fields(template.id, body: "# Meeting Note\n\nA template for meeting notes.")

      {:ok, page} = Brain.create_page(brain.id, %{title: "Overview"}, actor: user)
      set_page_fields(page.id, body: "# Overview")

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "### Brain Guide"
      assert context =~ "Types:"
      assert context =~ "Meeting Note"
    end

    test "omits the ### Brain Guide header when constitution, guides, and types are all empty",
         %{user: user, brain: brain, page: page} do
      context = BrainContext.build(brain.id, page.id, actor: user)
      refute context =~ "### Brain Guide"
    end

    test "surfaces the active page's type in the frontmatter line", %{
      user: user,
      brain: brain,
      page: page
    } do
      set_page_fields(page.id, frontmatter: %{"type" => "research-note"})

      context = BrainContext.build(brain.id, page.id, actor: user)
      assert context =~ "Frontmatter:"
      assert context =~ "research-note"
    end
  end

  describe "page neighborhood" do
    test "omits the deprecated 'Brain Tools' blurb", %{user: user, brain: brain, page: page} do
      context = BrainContext.build(brain.id, page.id, actor: user)
      refute context =~ "Brain Tools"
    end

    test "shows ancestors, active page, and siblings", %{user: user, brain: brain} do
      {:ok, parent} = Brain.create_page(brain.id, %{title: "Parent"}, actor: user)

      {:ok, active} =
        Brain.create_page(brain.id, %{title: "Active", parent_page_id: parent.id}, actor: user)

      {:ok, _sibling} =
        Brain.create_page(brain.id, %{title: "Sibling", parent_page_id: parent.id}, actor: user)

      context = BrainContext.build(brain.id, active.id, actor: user)
      assert context =~ "Parent"
      assert context =~ "Active [ACTIVE]"
      assert context =~ "Sibling"
    end

    test "shows children of the active page, indented", %{user: user, brain: brain} do
      {:ok, active} = Brain.create_page(brain.id, %{title: "Active"}, actor: user)

      {:ok, _child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: active.id}, actor: user)

      context = BrainContext.build(brain.id, active.id, actor: user)
      assert context =~ "Active [ACTIVE]"
      # Child appears indented under active
      assert context =~ ~r/Active \[ACTIVE\][^\n]*\n\s+- Child/
    end

    test "renders page ids in the neighborhood so the agent can target them",
         %{user: user, brain: brain} do
      {:ok, active} = Brain.create_page(brain.id, %{title: "Active"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Child", parent_page_id: active.id}, actor: user)

      context = BrainContext.build(brain.id, active.id, actor: user)
      # Both the active page and its child surface their ids (assert on the id
      # string, not exact label formatting).
      assert context =~ active.id
      assert context =~ child.id
    end

    test "truncates siblings beyond the cap with a '... +N more' line", %{
      user: user,
      brain: brain
    } do
      {:ok, active} = Brain.create_page(brain.id, %{title: "Active"}, actor: user)

      # Create 15 sibling roots; cap is 10 → 5 hidden (minus the active slot)
      for i <- 1..15 do
        {:ok, _} = Brain.create_page(brain.id, %{title: "Root #{i}"}, actor: user)
      end

      context = BrainContext.build(brain.id, active.id, actor: user)
      assert context =~ ~r/\+\d+ more sibling/
      assert context =~ "Active [ACTIVE]"
    end

    test "adds a footer with total page count when the neighborhood is a subset", %{
      user: user,
      brain: brain
    } do
      {:ok, root} = Brain.create_page(brain.id, %{title: "Root"}, actor: user)

      # Off-neighborhood pages (cousins) so the total exceeds the rendered set
      for i <- 1..5 do
        {:ok, other_root} = Brain.create_page(brain.id, %{title: "Other #{i}"}, actor: user)

        {:ok, _} =
          Brain.create_page(
            brain.id,
            %{title: "Cousin #{i}", parent_page_id: other_root.id},
            actor: user
          )
      end

      context = BrainContext.build(brain.id, root.id, actor: user)
      assert context =~ "brain has"
      assert context =~ "pages total"
      assert context =~ "read_brain"
    end
  end
end
