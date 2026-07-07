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
end
