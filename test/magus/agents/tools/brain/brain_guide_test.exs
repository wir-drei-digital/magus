defmodule Magus.Agents.Tools.Brain.BrainGuideTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Brain.BrainGuide
  alias Magus.Brain

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

    attrs =
      if kind = Keyword.get(opts, :kind),
        do: Map.put(attrs, :kind, kind),
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

  # ---------------------------------------------------------------------------
  # display_name / summarize_output (smoke)
  # ---------------------------------------------------------------------------

  describe "display_name/0 and summarize_output/1" do
    test "provides display name" do
      assert BrainGuide.display_name() =~ "guide" or BrainGuide.display_name() != ""
    end

    test "summarizes an error" do
      assert BrainGuide.summarize_output(%{error: "boom"}) =~ "Error"
    end
  end

  # ---------------------------------------------------------------------------
  # run/2 — context validation
  # ---------------------------------------------------------------------------

  describe "run/2 context validation" do
    test "errors when required context is missing" do
      assert {:ok, %{error: error}} = BrainGuide.run(%{action: "get_guide"}, %{})
      assert error =~ "Missing required context"
    end

    test "errors on unknown action" do
      %{user: user, brain: brain} = setup_brain()

      assert {:ok, %{error: error}} =
               BrainGuide.run(%{action: "bogus"}, default_context(user, brain.id))

      assert error =~ "Unknown action"
    end
  end

  # ---------------------------------------------------------------------------
  # get_guide
  # ---------------------------------------------------------------------------

  describe "get_guide action" do
    test "returns constitution, inherited section guide, and matching type template" do
      %{user: user, brain: brain} = setup_brain()

      {:ok, _brain} =
        Brain.set_brain_instructions(
          brain,
          %{instructions: "Always cite your sources."},
          actor: user
        )

      root = create_page!(brain.id, "Research", user)

      write_body!(
        root,
        """
        ---
        instructions: Keep entries dated and cite primary sources.
        ---

        # Research
        """,
        user
      )

      template =
        create_page!(brain.id, "Paper", user, kind: :template)

      write_body!(
        template,
        "# Paper\n\nA template for summarizing a research paper.",
        user
      )

      page =
        create_page!(brain.id, "Attention Is All You Need", user, parent_page_id: root.id)

      page =
        write_body!(
          page,
          """
          ---
          type: Paper
          ---

          # Attention Is All You Need
          """,
          user
        )

      context = default_context(user, brain.id)

      assert {:ok, result} =
               BrainGuide.run(%{action: "get_guide", page_id: page.id}, context)

      assert result.action == "get_guide"
      assert result.constitution =~ "Always cite your sources."

      assert [%{title: "Research", instructions: instructions}] = result.section_guides
      assert instructions =~ "Keep entries dated and cite primary sources."

      assert result.type_template.title == "Paper"
      assert result.type_template.page_id == template.id
    end

    test "type_template is nil when the page has no type" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Untyped Page", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               BrainGuide.run(%{action: "get_guide", page_id: page.id}, context)

      assert result.action == "get_guide"
      assert result.type_template == nil
    end

    test "type_template is nil when the page's type has no matching template" do
      %{user: user, brain: brain} = setup_brain()

      page = create_page!(brain.id, "Orphan Typed Page", user)

      page =
        write_body!(
          page,
          """
          ---
          type: Nonexistent
          ---

          # Orphan Typed Page
          """,
          user
        )

      context = default_context(user, brain.id)

      assert {:ok, result} =
               BrainGuide.run(%{action: "get_guide", page_id: page.id}, context)

      assert result.type_template == nil
    end

    test "resolves the page by page_title within the resolved brain" do
      %{user: user, brain: brain} = setup_brain()
      _page = create_page!(brain.id, "Findable Page", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               BrainGuide.run(
                 %{action: "get_guide", page_title: "Findable Page"},
                 context
               )

      assert result.action == "get_guide"
    end

    test "errors when no page is specified and none is active in context" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, %{error: error}} = BrainGuide.run(%{action: "get_guide"}, context)
      assert error =~ "page"
    end
  end
end
