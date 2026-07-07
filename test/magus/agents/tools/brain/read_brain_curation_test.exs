defmodule Magus.Agents.Tools.Brain.ReadBrainCurationTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Brain.ReadBrain
  alias Magus.Brain

  # ---------------------------------------------------------------------------
  # Setup helpers (mirrors read_brain_test.exs / brain_guide_test.exs)
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
  # list_curation_candidates: untyped / off_template / unfiled
  # ---------------------------------------------------------------------------

  describe "list_curation_candidates: untyped/off_template/unfiled" do
    test "untyped: flags a content page with no frontmatter type" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "No Type Here", user)
      write_body!(page, "# No Type Here\n\nSome content, no type set.", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      assert page.id in Enum.map(result.untyped, & &1.page_id)
    end

    test "untyped: does NOT flag a page with a frontmatter type set" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Typed Page", user)

      write_body!(
        page,
        """
        ---
        type: Paper
        ---

        # Typed Page
        """,
        user
      )

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      refute page.id in Enum.map(result.untyped, & &1.page_id)
    end

    test "off_template: flags a typed page missing a heading its template declares" do
      %{user: user, brain: brain} = setup_brain()

      template = create_page!(brain.id, "Paper", user, kind: :template)

      write_body!(
        template,
        """
        # Paper

        ## Summary

        ## Method

        ## Results
        """,
        user
      )

      page = create_page!(brain.id, "Attention Is All You Need", user)

      page =
        write_body!(
          page,
          """
          ---
          type: Paper
          ---

          # Attention Is All You Need

          ## Summary

          Some summary text, but no Method or Results section.
          """,
          user
        )

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      assert page.id in Enum.map(result.off_template, & &1.page_id)

      entry = Enum.find(result.off_template, &(&1.page_id == page.id))
      assert "Method" in entry.missing_headings
      assert "Results" in entry.missing_headings
      refute "Summary" in entry.missing_headings
    end

    test "off_template: does NOT flag a typed page that has every template heading" do
      %{user: user, brain: brain} = setup_brain()

      template = create_page!(brain.id, "Paper", user, kind: :template)

      write_body!(
        template,
        """
        # Paper

        ## Method
        """,
        user
      )

      page = create_page!(brain.id, "Complete Paper", user)

      page =
        write_body!(
          page,
          """
          ---
          type: Paper
          ---

          # Complete Paper

          ## Method

          Fully documented.
          """,
          user
        )

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      refute page.id in Enum.map(result.off_template, & &1.page_id)
    end

    test "off_template: does NOT flag a typed page whose type has no matching template" do
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
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      refute page.id in Enum.map(result.off_template, & &1.page_id)
    end

    test "unfiled: flags a root page (no parent) with no inbound wikilink" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "Root No Links", user)
      write_body!(page, "# Root No Links\n\nJust sitting here.", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      assert page.id in Enum.map(result.unfiled, & &1.page_id)
    end

    test "unfiled: does NOT flag a root page that has an inbound wikilink" do
      %{user: user, brain: brain} = setup_brain()
      target = create_page!(brain.id, "Linked Root", user)
      linker = create_page!(brain.id, "Linker", user)
      write_body!(linker, "see [[Linked Root]]", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      refute target.id in Enum.map(result.unfiled, & &1.page_id)
    end

    test "unfiled: does NOT flag a page that has a parent, even without inbound links" do
      %{user: user, brain: brain} = setup_brain()
      parent = create_page!(brain.id, "Parent", user)
      write_body!(parent, "# Parent", user)
      child = create_page!(brain.id, "Child No Links", user, parent_page_id: parent.id)
      write_body!(child, "# Child No Links", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      refute child.id in Enum.map(result.unfiled, & &1.page_id)
    end

    test "a well-formed control page appears in none of the three new categories" do
      %{user: user, brain: brain} = setup_brain()

      template = create_page!(brain.id, "Paper", user, kind: :template)
      write_body!(template, "# Paper\n\n## Method\n", user)

      parent = create_page!(brain.id, "Filed Under", user)
      write_body!(parent, "# Filed Under", user)

      control = create_page!(brain.id, "Well Formed Paper", user, parent_page_id: parent.id)

      control =
        write_body!(
          control,
          """
          ---
          type: Paper
          ---

          # Well Formed Paper

          ## Method

          Documented in full.
          """,
          user
        )

      linker = create_page!(brain.id, "Linker Two", user)
      write_body!(linker, "see [[Well Formed Paper]]", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      refute control.id in Enum.map(result.untyped, & &1.page_id)
      refute control.id in Enum.map(result.off_template, & &1.page_id)
      refute control.id in Enum.map(result.unfiled, & &1.page_id)
    end

    test "counts map and summarize_output include the three new counts" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "No Type Here", user)
      write_body!(page, "# No Type Here", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      assert Map.has_key?(result.counts, :untyped)
      assert Map.has_key?(result.counts, :off_template)
      assert Map.has_key?(result.counts, :unfiled)
      assert result.counts.untyped >= 1

      summary = ReadBrain.summarize_output(result)
      assert summary =~ "untyped"
      assert summary =~ "off_template" or summary =~ "off template"
      assert summary =~ "unfiled"
    end

    test "entries carry no page body (metadata only)" do
      %{user: user, brain: brain} = setup_brain()
      page = create_page!(brain.id, "No Type Here", user)
      write_body!(page, "secret body text", user)

      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      entries = result.untyped ++ result.off_template ++ result.unfiled

      Enum.each(entries, fn e -> refute Map.has_key?(e, :body) end)
    end

    test "empty brain returns zeroed counts for the three new categories" do
      %{user: user, brain: brain} = setup_brain()
      context = default_context(user, brain.id)

      assert {:ok, result} =
               ReadBrain.run(%{"action" => "list_curation_candidates"}, context)

      assert result.counts.untyped == 0
      assert result.counts.off_template == 0
      assert result.counts.unfiled == 0
      assert result.untyped == []
      assert result.off_template == []
      assert result.unfiled == []
    end
  end
end
