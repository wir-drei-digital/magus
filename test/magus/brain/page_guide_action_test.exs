defmodule Magus.Brain.PageGuideActionTest do
  @moduledoc """
  Tests the `:guide_for_page` generic action (SPA bottom-bar Guide tab):
  the per-page effective Guide as a JSON-safe map, assembled by
  `Magus.Brain.Guide` exactly like the agent-facing `brain_guide get_guide`.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Brain

  defp setup_brain(opts \\ []) do
    user = generate(user())

    {:ok, brain} =
      Brain.create_brain(%{title: Keyword.get(opts, :title, "Guide Brain")}, actor: user)

    %{user: user, brain: brain}
  end

  defp create_page!(brain_id, title, user, opts \\ []) do
    attrs = %{title: title}

    attrs =
      if pid = Keyword.get(opts, :parent_page_id),
        do: Map.put(attrs, :parent_page_id, pid),
        else: attrs

    attrs =
      if kind = Keyword.get(opts, :kind),
        do: Map.put(attrs, :kind, kind),
        else: attrs

    {:ok, page} = Brain.create_page(brain_id, attrs, actor: user)
    page
  end

  defp write_body!(page, body, user) do
    {:ok, updated} =
      Brain.update_page_body(page, %{body: body, base_version: page.lock_version}, actor: user)

    updated
  end

  describe "guide_for_page" do
    test "returns the full cascade: constitution, inherited section guides, type + template" do
      %{user: user, brain: brain} = setup_brain()

      {:ok, _} =
        Brain.set_brain_instructions(brain, %{instructions: "One concept per page."}, actor: user)

      parent = create_page!(brain.id, "Research", user)

      parent =
        write_body!(
          parent,
          "---\ninstructions: Cite at least one source.\n---\n# Research\n",
          user
        )

      child = create_page!(brain.id, "Attention Paper", user, parent_page_id: parent.id)

      child =
        write_body!(
          child,
          "---\ninstructions: Summarize in three bullets.\ntype: paper\n---\n# Attention\n",
          user
        )

      template = create_page!(brain.id, "Paper", user, kind: :template)
      _template = write_body!(template, "# Paper\n\nSkeleton for paper notes.", user)

      assert {:ok, guide} = Brain.page_guide(child.id, actor: user)

      assert guide.constitution == "One concept per page."

      # Root -> page: the parent's guide first, the page's own last (nearest wins).
      assert [
               %{page_id: parent_id, title: "Research", instructions: parent_instructions},
               %{page_id: child_id, title: "Attention Paper", instructions: child_instructions}
             ] = guide.section_guides

      assert parent_id == parent.id
      assert child_id == child.id
      assert parent_instructions == "Cite at least one source."
      assert child_instructions == "Summarize in three bullets."

      assert guide.page_type == "paper"
      assert %{page_id: template_id, title: "Paper"} = guide.type_template
      assert template_id == template.id
    end

    test "returns an empty guide for a bare page in a bare brain" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Loose Note", user)

      assert {:ok, guide} = Brain.page_guide(page.id, actor: user)

      assert guide.constitution == nil
      assert guide.section_guides == []
      assert guide.page_type == nil
      assert guide.type_template == nil
    end

    test "a typed page without a matching template resolves type but no template" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Untemplated", user)
      page = write_body!(page, "---\ntype: journal\n---\n# Untemplated\n", user)

      assert {:ok, guide} = Brain.page_guide(page.id, actor: user)
      assert guide.page_type == "journal"
      assert guide.type_template == nil
    end

    test "a stranger cannot read another user's page guide" do
      %{user: owner, brain: brain} = setup_brain()
      stranger = generate(user())
      page = create_page!(brain.id, "Private", owner)

      assert {:error, _} = Brain.page_guide(page.id, actor: stranger)
    end
  end
end
