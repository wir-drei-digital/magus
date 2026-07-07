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

  # ---------------------------------------------------------------------------
  # set_brain_guide
  # ---------------------------------------------------------------------------

  describe "set_brain_guide action" do
    test "writes the brain's constitution and a subsequent get_guide returns it" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Notes", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               BrainGuide.run(
                 %{action: "set_brain_guide", instructions: "Always cite your sources."},
                 context
               )

      assert result.action == "set_brain_guide"
      assert result.brain_id == brain.id

      assert {:ok, guide_result} =
               BrainGuide.run(%{action: "get_guide", page_id: page.id}, context)

      assert guide_result.constitution =~ "Always cite your sources."
    end

    test "errors when instructions is missing" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, %{error: error}} =
               BrainGuide.run(%{action: "set_brain_guide"}, context)

      assert error =~ "instructions"
    end

    test "errors when instructions is blank" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, %{error: error}} =
               BrainGuide.run(%{action: "set_brain_guide", instructions: "   "}, context)

      assert error =~ "instructions"
    end
  end

  # ---------------------------------------------------------------------------
  # set_page_guide
  # ---------------------------------------------------------------------------

  describe "set_page_guide action" do
    test "sets a page's instructions frontmatter and a child page inherits it via get_guide" do
      %{user: user, brain: brain} = setup_brain()
      parent = create_page!(brain.id, "Research", user)
      child = create_page!(brain.id, "Attention Is All You Need", user, parent_page_id: parent.id)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               BrainGuide.run(
                 %{
                   action: "set_page_guide",
                   page_id: parent.id,
                   instructions: "Keep entries dated and cite primary sources."
                 },
                 context
               )

      assert result.action == "set_page_guide"
      assert result.page_id == parent.id

      # The frontmatter cache is rebuilt by update_page_body's derived-state
      # pipeline; confirm it landed there (not just in the raw body string).
      {:ok, reloaded_parent} = Brain.get_page(parent.id, actor: user)
      assert reloaded_parent.frontmatter["instructions"] =~ "cite primary sources"

      assert {:ok, guide_result} =
               BrainGuide.run(%{action: "get_guide", page_id: child.id}, context)

      assert [%{title: "Research", instructions: instructions}] = guide_result.section_guides
      assert instructions =~ "Keep entries dated and cite primary sources."
    end

    test "accepts multi-line instructions and round-trips them through get_guide" do
      %{user: user, brain: brain} = setup_brain()
      parent = create_page!(brain.id, "Papers", user)
      child = create_page!(brain.id, "Some Paper", user, parent_page_id: parent.id)

      context = default_context(user, brain.id)
      multi_line = "Section guide:\n\n- One paper per page.\n- Cite the arXiv link."

      assert {:ok, result} =
               BrainGuide.run(
                 %{action: "set_page_guide", page_id: parent.id, instructions: multi_line},
                 context
               )

      assert result.action == "set_page_guide"

      assert {:ok, guide_result} =
               BrainGuide.run(%{action: "get_guide", page_id: child.id}, context)

      assert [%{title: "Papers", instructions: instructions}] = guide_result.section_guides
      assert instructions =~ "One paper per page."
      assert instructions =~ "Cite the arXiv link."
    end

    test "resolves the page by page_title" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Titled Page", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               BrainGuide.run(
                 %{
                   action: "set_page_guide",
                   page_title: "Titled Page",
                   instructions: "Guide text."
                 },
                 context
               )

      assert result.action == "set_page_guide"
      assert result.page_id == page.id
    end

    test "merges into existing frontmatter without clobbering type or tags" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Typed Page", user)

      page =
        write_body!(
          page,
          "---\ntype: Paper\ntags: [ml, research]\n---\n\n# Typed Page\n",
          user
        )

      context = default_context(user, brain.id)

      assert {:ok, _result} =
               BrainGuide.run(
                 %{
                   action: "set_page_guide",
                   page_id: page.id,
                   instructions: "One paper per page."
                 },
                 context
               )

      {:ok, reloaded} = Brain.get_page(page.id, actor: user)
      assert reloaded.frontmatter["instructions"] == "One paper per page."
      assert reloaded.frontmatter["type"] == "Paper"
      assert reloaded.frontmatter["tags"] == ["ml", "research"]
      assert reloaded.body =~ "# Typed Page"
    end

    test "errors when instructions is missing" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Notes", user)
      context = default_context(user, brain.id)

      assert {:ok, %{error: error}} =
               BrainGuide.run(%{action: "set_page_guide", page_id: page.id}, context)

      assert error =~ "instructions"
    end

    test "errors when instructions is blank" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Notes", user)
      context = default_context(user, brain.id)

      assert {:ok, %{error: error}} =
               BrainGuide.run(
                 %{action: "set_page_guide", page_id: page.id, instructions: "   "},
                 context
               )

      assert error =~ "instructions"
    end

    test "errors when no page is specified and none is active in context" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, %{error: error}} =
               BrainGuide.run(
                 %{action: "set_page_guide", instructions: "Guide text."},
                 context
               )

      # Same "no page specified" message get_guide's equivalent test asserts
      # on (both actions resolve the page via BrainResolver.resolve_page),
      # not just a substring match that "set_page_guide" itself would satisfy.
      assert error =~ "No page specified"
    end

    test "reports an error instead of corrupting the body when existing frontmatter is malformed" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Malformed Frontmatter Page", user)
      malformed_body = "---\nicon: [unterminated\n---\nx\n"
      page = write_body!(page, malformed_body, user)

      context = default_context(user, brain.id)

      assert {:ok, %{error: error}} =
               BrainGuide.run(
                 %{action: "set_page_guide", page_id: page.id, instructions: "Guide text."},
                 context
               )

      assert error =~ "frontmatter"

      {:ok, reloaded} = Brain.get_page(page.id, actor: user)
      assert reloaded.body == malformed_body
    end

    test "succeeds even when the page was written by someone else since it was last read" do
      # set_page_guide resolves the page fresh (via BrainResolver) on every
      # call rather than trusting a caller-supplied lock_version, so an
      # intervening write from elsewhere does not produce a false-positive
      # conflict: the tool's own read is never stale by the time it writes.
      # (The underlying update_body optimistic-lock mechanism that a genuine
      # concurrent conflict would hit is exercised directly, independent of
      # any one caller, in test/magus/brain/page/update_body_test.exs
      # "optimistic locking".)
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Contested Page", user)
      {:ok, _bumped} = Brain.update_page_body(page, %{body: "# X", base_version: 0}, actor: user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               BrainGuide.run(
                 %{
                   action: "set_page_guide",
                   page_id: page.id,
                   instructions: "Guide after an intervening write."
                 },
                 context
               )

      assert result.action == "set_page_guide"

      {:ok, reloaded} = Brain.get_page(page.id, actor: user)
      assert reloaded.frontmatter["instructions"] =~ "Guide after an intervening write."
      # The intervening write's body content is preserved (set_page_guide
      # only merges the instructions key, it doesn't clobber body content).
      assert reloaded.body =~ "# X"
    end
  end

  # ---------------------------------------------------------------------------
  # define_type
  # ---------------------------------------------------------------------------

  describe "define_type action" do
    test "creates a :template page listed by templates_for_brain and excluded from list_pages" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, result} =
               BrainGuide.run(
                 %{
                   action: "define_type",
                   type_name: "Meeting Note",
                   template_body: "# Meeting Note\n\nAttendees, agenda, action items."
                 },
                 context
               )

      assert result.action == "define_type"
      assert result.type == "Meeting Note"
      assert is_binary(result.page_id)

      {:ok, templates} = Brain.templates_for_brain(brain.id, actor: user)
      assert Enum.any?(templates, &(&1.id == result.page_id and &1.title == "Meeting Note"))

      {:ok, pages} = Brain.list_pages(brain.id, actor: user)
      refute Enum.any?(pages, &(&1.id == result.page_id))

      {:ok, page} = Brain.get_page(result.page_id, actor: user)
      assert page.kind == :template
      assert page.body =~ "Attendees, agenda, action items."
    end

    test "calling it again with the same type_name updates the same page (no duplicate)" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, first} =
               BrainGuide.run(
                 %{
                   action: "define_type",
                   type_name: "Meeting Note",
                   template_body: "# Meeting Note\n\nOriginal template body."
                 },
                 context
               )

      assert {:ok, second} =
               BrainGuide.run(
                 %{
                   action: "define_type",
                   type_name: "Meeting Note",
                   template_body: "# Meeting Note\n\nRevised template body."
                 },
                 context
               )

      assert second.page_id == first.page_id

      {:ok, templates} = Brain.templates_for_brain(brain.id, actor: user)

      matching = Enum.filter(templates, &(String.downcase(&1.title || "") == "meeting note"))
      assert length(matching) == 1

      {:ok, page} = Brain.get_page(first.page_id, actor: user)
      assert page.body =~ "Revised template body."
      refute page.body =~ "Original template body."
    end

    test "upserts case-insensitively against an existing template title" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, first} =
               BrainGuide.run(
                 %{
                   action: "define_type",
                   type_name: "Meeting Note",
                   template_body: "# Meeting Note\n\nOriginal."
                 },
                 context
               )

      assert {:ok, second} =
               BrainGuide.run(
                 %{
                   action: "define_type",
                   type_name: "meeting note",
                   template_body: "# meeting note\n\nUpdated via different casing."
                 },
                 context
               )

      assert second.page_id == first.page_id
    end

    test "merges description into the template's frontmatter and it surfaces via get_guide's types index" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, result} =
               BrainGuide.run(
                 %{
                   action: "define_type",
                   type_name: "Paper",
                   template_body: "# Paper\n\nSome generic first line.",
                   description: "A template for summarizing a research paper."
                 },
                 context
               )

      {:ok, page} = Brain.get_page(result.page_id, actor: user)
      assert page.frontmatter["description"] == "A template for summarizing a research paper."

      # The description surfaces in the types index (Guide.build_types),
      # which get_guide's caller assembles for any page in the brain.
      other_page = create_page!(brain.id, "Some Page", user)

      assert {:ok, guide_result} =
               BrainGuide.run(%{action: "get_guide", page_id: other_page.id}, context)

      # get_guide itself only returns the page's own matching type_template,
      # not the full types index; exercise the shared Guide module directly
      # (the same computation Magus.Agents.Context.BrainContext renders).
      {:ok, brain_record} = Brain.get_brain(brain.id, actor: user)
      {:ok, pages} = Brain.list_pages(brain.id, actor: user)
      guide = Magus.Brain.Guide.for_page(brain_record, other_page, pages, user)

      assert Enum.any?(
               guide.types,
               &(&1.title == "Paper" and
                   &1.description == "A template for summarizing a research paper.")
             )

      # get_guide's own result stays unaffected by this assertion path;
      # sanity-check it still runs without error.
      assert guide_result.action == "get_guide"
    end

    test "errors when type_name is missing" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, %{error: error}} =
               BrainGuide.run(
                 %{action: "define_type", template_body: "# Body"},
                 context
               )

      assert error =~ "type_name"
    end

    test "errors when template_body is missing" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, %{error: error}} =
               BrainGuide.run(
                 %{action: "define_type", type_name: "Meeting Note"},
                 context
               )

      assert error =~ "template_body"
    end
  end
end
