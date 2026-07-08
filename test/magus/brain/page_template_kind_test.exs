defmodule Magus.Brain.PageTemplateKindTest do
  @moduledoc """
  Task B3: `:template` pages are meta content, not knowledge. They must:

    * be excluded from `for_brain`/`list_pages` (the page tree / list source)
    * be returned by the new `templates_for_brain` read
    * never enqueue Super Brain extraction (`ExtractBrainPage`), whether the
      template is freshly created or its body is later updated

  Regular `:page` pages are asserted alongside templates in the same tests
  so a regression that excludes everything (rather than just templates)
  would also fail.
  """

  use Magus.ResourceCase, async: false

  use Oban.Testing, repo: Magus.Repo

  alias Magus.Brain

  setup do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    %{user: user, brain: brain}
  end

  describe "for_brain / list_pages excludes templates" do
    test "a :template page is not returned by list_pages", %{user: user, brain: brain} do
      {:ok, regular} = Brain.create_page(brain.id, %{title: "Regular Page"}, actor: user)

      {:ok, template} =
        Brain.create_page(brain.id, %{title: "Template Page", kind: :template}, actor: user)

      assert {:ok, pages} = Brain.list_pages(brain.id, actor: user)
      page_ids = Enum.map(pages, & &1.id)

      assert regular.id in page_ids
      refute template.id in page_ids
    end
  end

  describe "templates_for_brain" do
    test "returns :template pages and excludes :page pages", %{user: user, brain: brain} do
      {:ok, regular} = Brain.create_page(brain.id, %{title: "Regular Page"}, actor: user)

      {:ok, template} =
        Brain.create_page(brain.id, %{title: "Template Page", kind: :template}, actor: user)

      assert {:ok, templates} = Brain.templates_for_brain(brain.id, actor: user)
      template_ids = Enum.map(templates, & &1.id)

      assert template.id in template_ids
      refute regular.id in template_ids
    end

    test "does not return templates from another user's brain", %{user: user} do
      other_user = generate(user())
      other_brain = generate(brain(user_id: other_user.id))

      {:ok, _template} =
        Brain.create_page(other_brain.id, %{title: "Secret Template", kind: :template},
          actor: other_user
        )

      assert {:ok, templates} = Brain.templates_for_brain(other_brain.id, actor: user)
      assert templates == []
    end
  end

  describe "Super Brain extraction skip for templates" do
    test "updating a :template page's body does not enqueue ExtractBrainPage", %{
      user: user,
      brain: brain
    } do
      {:ok, template} =
        Brain.create_page(brain.id, %{title: "Template Page", kind: :template}, actor: user)

      updated = replace_page_body(template, "# Template body\n\nSome content.", user)

      refute_enqueued(
        worker: Magus.SuperBrain.Workers.ExtractBrainPage,
        args: %{"resource_id" => updated.id}
      )
    end

    test "updating a regular :page's body still enqueues ExtractBrainPage", %{
      user: user,
      brain: brain
    } do
      {:ok, regular} = Brain.create_page(brain.id, %{title: "Regular Page"}, actor: user)

      updated = replace_page_body(regular, "# Regular body\n\nSome content.", user)

      assert_enqueued(
        worker: Magus.SuperBrain.Workers.ExtractBrainPage,
        args: %{"resource_id" => updated.id}
      )
    end
  end

  # Templates must stay meta on EVERY knowledge surface, not just listing
  # and graph extraction: no chunks (semantic search / RAG source), no
  # full-text hits, no title resolution, no wikilink binding.
  describe "templates stay meta: search, resolution, links" do
    test "a template body is never chunked; a regular page is", %{user: user, brain: brain} do
      {:ok, regular} = Brain.create_page(brain.id, %{title: "Notes"}, actor: user)

      {:ok, template} =
        Brain.create_page(brain.id, %{title: "Meeting Note", kind: :template}, actor: user)

      body = "# Heading\n\nEnough prose to produce at least one chunk of content."
      _ = replace_page_body(regular, body, user)
      _ = replace_page_body(template, body, user)

      assert chunk_count(regular.id) > 0
      assert chunk_count(template.id) == 0
    end

    test "full-text search never returns template hits", %{user: user, brain: brain} do
      {:ok, regular} = Brain.create_page(brain.id, %{title: "Zebra Research"}, actor: user)

      {:ok, template} =
        Brain.create_page(brain.id, %{title: "Zebra Template", kind: :template}, actor: user)

      _ = replace_page_body(regular, "Zebras are equids with striking stripes.", user)
      _ = replace_page_body(template, "Zebras template skeleton: stripes go here.", user)

      hits = Brain.search_pages_text(brain.id, "zebras", actor: user)
      hit_ids = Enum.map(hits, & &1.page_id)

      assert regular.id in hit_ids
      refute template.id in hit_ids
    end

    test "title resolution (by_title_in_brain) skips templates", %{user: user, brain: brain} do
      {:ok, _template} =
        Brain.create_page(brain.id, %{title: "Decision", kind: :template}, actor: user)

      assert {:ok, []} = Brain.find_page_by_title(brain.id, "Decision", actor: user)

      {:ok, regular} = Brain.create_page(brain.id, %{title: "Decision"}, actor: user)
      assert {:ok, [found]} = Brain.find_page_by_title(brain.id, "Decision", actor: user)
      assert found.id == regular.id
    end

    test "a wikilink never binds to a template", %{user: user, brain: brain} do
      {:ok, template} =
        Brain.create_page(brain.id, %{title: "Spec", kind: :template}, actor: user)

      {:ok, linker} = Brain.create_page(brain.id, %{title: "Linker"}, actor: user)
      _ = replace_page_body(linker, "See [[Spec]] for the shape.", user)

      assert {:ok, []} = Brain.list_backlinks(template.id, actor: user)

      # Same wikilink binds once a CONTENT page with that title exists.
      {:ok, regular} = Brain.create_page(brain.id, %{title: "Spec"}, actor: user)
      {:ok, linker} = Brain.get_page(linker.id, actor: user)
      _ = replace_page_body(linker, "See [[Spec]] for the real shape.", user)

      assert {:ok, [backlink]} = Brain.list_backlinks(regular.id, actor: user)
      assert backlink.source_page_id == linker.id
    end
  end

  defp chunk_count(page_id) do
    import Ecto.Query
    {:ok, bin} = Ecto.UUID.dump(page_id)
    Magus.Repo.aggregate(from(c in "brain_page_chunks", where: c.page_id == ^bin), :count)
  end
end
