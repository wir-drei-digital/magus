defmodule Magus.Agents.Tools.Brain.EditBrainTest do
  @moduledoc """
  Covers the C3 EditBrain action set (file-edit shape), writes only:

    * create_brain, rename_page, move_page, delete_page (structural)
    * write_page :create | :replace | :append | :prepend
    * edit_page string mode and line-range mode (incl. pure insertion)
    * clear_page, undo_last_edit
    * removed-action stubs (add_block/edit_block/delete_block/move_block/link)

  Reads (read_page, peek_page, read_source) moved to ReadBrain and are
  covered by `Magus.Agents.Tools.Brain.ReadBrainTest`.

  Every successful action echoes a `current` map (`brain_id`, `brain_title`,
  `page_id`, `page_title`) so the agent can stay oriented between calls.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Brain.EditBrain
  alias Magus.Brain
  alias Magus.FeatureUsage

  require Ash.Query

  defp setup_brain do
    user = generate(user())
    {:ok, brain} = Brain.create_brain(%{title: "Test Brain"}, actor: user)
    %{user: user, brain: brain}
  end

  defp setup_brain_with_page(body) do
    %{user: user, brain: brain} = setup_brain()
    {:ok, page} = Brain.create_page(brain.id, %{title: "Page One"}, actor: user)
    page = maybe_write_body(page, body, user)

    %{
      user: user,
      brain: brain,
      page: page,
      context: %{user_id: user.id, user: user, brain_id: brain.id, brain_page_id: page.id}
    }
  end

  defp maybe_write_body(page, "", _user), do: page

  defp maybe_write_body(page, body, user) do
    {:ok, updated} =
      Brain.update_page_body(page, %{body: body, base_version: page.lock_version}, actor: user)

    updated
  end

  defp context_for(user, brain_id, page_id) do
    %{user_id: user.id, user: user, brain_id: brain_id, brain_page_id: page_id}
  end

  defp read_page_body!(page_id, user) do
    {:ok, p} = Brain.get_page(page_id, actor: user)
    p.body || ""
  end

  # ---------------------------------------------------------------------------
  # display_name / metadata
  # ---------------------------------------------------------------------------

  describe "display_name/0" do
    test "exposes a human-readable name" do
      assert EditBrain.display_name() =~ "brain"
    end
  end

  # ---------------------------------------------------------------------------
  # action validation
  # ---------------------------------------------------------------------------

  describe "action validation" do
    test "missing action returns a helpful error" do
      user = generate(user())
      assert {:ok, %{error: error}} = EditBrain.run(%{}, %{user_id: user.id, user: user})
      assert error =~ "action"
    end

    test "unknown action returns a helpful error" do
      user = generate(user())

      assert {:ok, %{error: error}} =
               EditBrain.run(%{"action" => "fly"}, %{user_id: user.id, user: user})

      assert error =~ "Unknown action"
    end

    test "returns error when context is missing required keys" do
      assert {:ok, %{error: _}} =
               EditBrain.run(%{"action" => "write_page", "page_id" => Ash.UUID.generate()}, %{})
    end
  end

  # ---------------------------------------------------------------------------
  # Removed-action stubs (helpful redirects)
  # ---------------------------------------------------------------------------

  describe "removed actions return migration hints" do
    setup do
      user = generate(user())
      %{user: user, context: %{user_id: user.id, user: user}}
    end

    test "add_block points to write_page :append / edit_page line-range", %{context: ctx} do
      assert {:ok, %{error: error}} = EditBrain.run(%{"action" => "add_block"}, ctx)
      assert error =~ "removed"
      assert error =~ "write_page"
      assert error =~ "append"
    end

    test "edit_block points to edit_page", %{context: ctx} do
      assert {:ok, %{error: error}} = EditBrain.run(%{"action" => "edit_block"}, ctx)
      assert error =~ "removed"
      assert error =~ "edit_page"
    end

    test "delete_block points to edit_page line-range with empty new_content",
         %{context: ctx} do
      assert {:ok, %{error: error}} = EditBrain.run(%{"action" => "delete_block"}, ctx)
      assert error =~ "removed"
      assert error =~ "edit_page"
    end

    test "move_block points to edit_page + write_page :append", %{context: ctx} do
      assert {:ok, %{error: error}} = EditBrain.run(%{"action" => "move_block"}, ctx)
      assert error =~ "removed"
      assert error =~ "edit_page"
      assert error =~ "write_page"
    end

    test "link points to wikilinks in body", %{context: ctx} do
      assert {:ok, %{error: error}} = EditBrain.run(%{"action" => "link"}, ctx)
      assert error =~ "removed"
      assert error =~ "[[Page Name]]"
    end
  end

  # ---------------------------------------------------------------------------
  # create_brain
  # ---------------------------------------------------------------------------

  describe "create_brain action" do
    test "creates a brain and tracks the brains feature usage" do
      user = generate(user())
      context = %{user_id: user.id, user: user}
      refute FeatureUsage.discovered?(user.id, "brains")

      assert {:ok, %{action: "create_brain", brain_id: brain_id, brain_title: "Sourdough"} = res} =
               EditBrain.run(%{"action" => "create_brain", "title" => "Sourdough"}, context)

      assert is_binary(brain_id)
      assert FeatureUsage.discovered?(user.id, "brains")
      # current echo on create_brain carries the brain only.
      assert %{brain_id: ^brain_id, brain_title: "Sourdough"} = res.current
    end

    test "does not track when creation fails due to missing title" do
      user = generate(user())
      context = %{user_id: user.id, user: user}

      assert {:ok, %{error: "Missing required parameter: title"}} =
               EditBrain.run(%{"action" => "create_brain"}, context)

      refute FeatureUsage.discovered?(user.id, "brains")
    end

    test "creates brain in workspace when context includes workspace_id" do
      user = generate(user())
      ensure_workspace_plan(user)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "t-edit-brain-#{System.unique_integer([:positive])}"},
          actor: user
        )

      context = %{user_id: user.id, user: user, workspace_id: workspace.id}

      assert {:ok, %{action: "create_brain", brain_id: brain_id}} =
               EditBrain.run(%{"action" => "create_brain", "title" => "WS Brain"}, context)

      {:ok, brain} = Brain.get_brain(brain_id, actor: user)
      assert brain.workspace_id == workspace.id
    end

    test "creates personal brain when context has no workspace_id" do
      user = generate(user())
      context = %{user_id: user.id, user: user}

      assert {:ok, %{action: "create_brain", brain_id: brain_id}} =
               EditBrain.run(%{"action" => "create_brain", "title" => "Personal"}, context)

      {:ok, brain} = Brain.get_brain(brain_id, actor: user)
      assert is_nil(brain.workspace_id)
    end
  end

  # ---------------------------------------------------------------------------
  # write_page
  # ---------------------------------------------------------------------------

  describe "write_page action — fresh create" do
    test "creates a new page with a markdown body" do
      %{user: user, brain: brain} = setup_brain()
      ctx = %{user_id: user.id, user: user, brain_id: brain.id}

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => "Fresh Page",
                   "body" => "Hello world."
                 },
                 ctx
               )

      assert result.action == "write_page"
      assert result.page_title == "Fresh Page"
      assert result.mode == "create"
      assert is_binary(result.page_id)
      assert read_page_body!(result.page_id, user) =~ "Hello world."
    end

    test "strips a rogue leading `# Title` heading matching the page title" do
      %{user: user, brain: brain} = setup_brain()
      ctx = %{user_id: user.id, user: user, brain_id: brain.id}

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => "Notes",
                   "body" => "# Notes\n\nActual content."
                 },
                 ctx
               )

      body = read_page_body!(result.page_id, user)
      refute body =~ ~r/^#\s*Notes/
      assert body =~ "Actual content."
    end

    test "creates nested pages via slash-path" do
      %{user: user, brain: brain} = setup_brain()
      ctx = %{user_id: user.id, user: user, brain_id: brain.id}

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => "Projects/Alpha/Notes",
                   "body" => "Deep nest body."
                 },
                 ctx
               )

      assert result.page_title == "Notes"

      {:ok, leaf} = Brain.get_page(result.page_id, actor: user)
      assert leaf.depth == 2
      assert leaf.parent_page_id != nil
    end

    test "missing title with no page_id errors" do
      %{user: user, brain: brain} = setup_brain()
      ctx = %{user_id: user.id, user: user, brain_id: brain.id}

      assert {:ok, %{error: error}} =
               EditBrain.run(%{"action" => "write_page", "body" => "x"}, ctx)

      assert error =~ "title"
    end
  end

  describe "write_page action — collisions require mode" do
    setup do
      env = setup_brain_with_page("Original body")
      env
    end

    test "no mode + existing page returns mode_required payload with preview",
         %{context: ctx, page: page} do
      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => page.title,
                   "body" => "Other text."
                 },
                 ctx
               )

      assert result.error =~ "mode is REQUIRED"
      assert result.existing_page_id == page.id
      assert result.existing_page_title == page.title
      assert is_binary(result.body_preview)
      assert result.body_preview =~ "Original"
      assert result.last_modified_at
    end

    test "mode 'create' on existing page refuses to overwrite",
         %{context: ctx, page: page} do
      assert {:ok, %{error: error}} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => page.title,
                   "body" => "Other text.",
                   "mode" => "create"
                 },
                 ctx
               )

      assert error =~ "already exists" or error =~ "create"
    end

    test "mode 'replace' overwrites the body", %{context: ctx, page: page, user: user} do
      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => page.title,
                   "body" => "Brand new body.",
                   "mode" => "replace"
                 },
                 ctx
               )

      assert result.mode == "replace"
      body = read_page_body!(result.page_id, user)
      assert body == "Brand new body."
    end

    test "mode 'append' adds to the end", %{context: ctx, page: page, user: user} do
      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => page.title,
                   "body" => "Appended.",
                   "mode" => "append"
                 },
                 ctx
               )

      assert result.mode == "append"
      body = read_page_body!(result.page_id, user)
      assert body =~ "Original body"
      assert body =~ "Appended."
      # Append text comes AFTER original.
      [_, after_part] = String.split(body, "Original body", parts: 2)
      assert after_part =~ "Appended."
    end

    test "mode 'prepend' adds to the front", %{context: ctx, page: page, user: user} do
      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => page.title,
                   "body" => "Prepended.",
                   "mode" => "prepend"
                 },
                 ctx
               )

      assert result.mode == "prepend"
      body = read_page_body!(result.page_id, user)
      assert String.starts_with?(body, "Prepended.")
    end

    test "invalid mode returns descriptive error", %{context: ctx, page: page} do
      assert {:ok, %{error: error}} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => page.title,
                   "body" => "x",
                   "mode" => "zap"
                 },
                 ctx
               )

      assert error =~ "Invalid mode"
    end

    test "page_id targets the specific page even with mismatched title",
         %{context: ctx, page: page, brain: brain, user: user} do
      {:ok, other} = Brain.create_page(brain.id, %{title: "Other"}, actor: user)

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "page_id" => other.id,
                   "title" => "Ignored",
                   "body" => "Targeted body.",
                   "mode" => "replace"
                 },
                 ctx
               )

      assert result.page_id == other.id
      assert read_page_body!(other.id, user) == "Targeted body."
      # Original page untouched.
      assert read_page_body!(page.id, user) =~ "Original body"
    end
  end

  # ---------------------------------------------------------------------------
  # write_page — parent disambiguation (magus-ixu)
  # ---------------------------------------------------------------------------

  describe "write_page action — parent_page_id disambiguation" do
    # Two root pages, each with a child titled "Notes" (same title, different
    # parents). Used to prove the agent can target the right one.
    defp setup_duplicate_notes do
      %{user: user, brain: brain} = setup_brain()
      {:ok, projects} = Brain.create_page(brain.id, %{title: "Projects"}, actor: user)
      {:ok, archive} = Brain.create_page(brain.id, %{title: "Archive"}, actor: user)

      {:ok, projects_notes} =
        Brain.create_page(brain.id, %{title: "Notes", parent_page_id: projects.id}, actor: user)

      {:ok, archive_notes} =
        Brain.create_page(brain.id, %{title: "Notes", parent_page_id: archive.id}, actor: user)

      %{
        user: user,
        brain: brain,
        projects: projects,
        archive: archive,
        projects_notes: projects_notes,
        archive_notes: archive_notes,
        context: %{user_id: user.id, user: user, brain_id: brain.id}
      }
    end

    test "explicit parent_page_id wins on duplicate titles and leaves the sibling untouched" do
      %{
        user: user,
        archive: archive,
        projects_notes: projects_notes,
        archive_notes: archive_notes,
        context: ctx
      } = setup_duplicate_notes()

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => "Notes",
                   "parent_page_id" => archive.id,
                   "mode" => "append",
                   "body" => "X"
                 },
                 ctx
               )

      # Wrote into the Archive/Notes page, not Projects/Notes.
      assert result.page_id == archive_notes.id
      {:ok, written} = Brain.get_page(result.page_id, actor: user)
      assert written.parent_page_id == archive.id
      assert read_page_body!(archive_notes.id, user) =~ "X"

      # The other Notes (under Projects) is untouched.
      assert read_page_body!(projects_notes.id, user) == ""
    end

    test "ambiguous bare title returns a disambiguation error with candidates" do
      %{
        user: user,
        projects_notes: projects_notes,
        archive_notes: archive_notes,
        context: ctx
      } = setup_duplicate_notes()

      assert {:ok, %{error: err, candidates: cands}} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => "Notes",
                   "body" => "X"
                 },
                 ctx
               )

      assert err =~ "parent_page_id" or err =~ "Multiple"
      assert length(cands) == 2

      Enum.each(cands, fn c ->
        assert is_binary(c.page_id)
        assert is_binary(c.breadcrumb)
      end)

      candidate_ids = Enum.map(cands, & &1.page_id)
      assert projects_notes.id in candidate_ids
      assert archive_notes.id in candidate_ids

      # Neither Notes body changed.
      assert read_page_body!(projects_notes.id, user) == ""
      assert read_page_body!(archive_notes.id, user) == ""
    end

    test "creates a new page under a nested parent identified by id" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, top} = Brain.create_page(brain.id, %{title: "Top"}, actor: user)

      {:ok, mid} =
        Brain.create_page(brain.id, %{title: "Mid", parent_page_id: top.id}, actor: user)

      ctx = %{user_id: user.id, user: user, brain_id: brain.id}

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => "Sub",
                   "parent_page_id" => mid.id,
                   "body" => "Nested under mid."
                 },
                 ctx
               )

      assert result.page_title == "Sub"
      {:ok, created} = Brain.get_page(result.page_id, actor: user)
      assert created.parent_page_id == mid.id
      assert read_page_body!(created.id, user) =~ "Nested under mid."
    end

    test "rejects a parent_page_id that belongs to a different brain" do
      %{user: user, brain: brain} = setup_brain()

      # A page in a SECOND brain owned by the same user.
      {:ok, other_brain} = Brain.create_brain(%{title: "Other Brain"}, actor: user)
      {:ok, foreign_parent} = Brain.create_page(other_brain.id, %{title: "Foreign"}, actor: user)

      ctx = %{user_id: user.id, user: user, brain_id: brain.id}

      assert {:ok, %{error: err}} =
               EditBrain.run(
                 %{
                   "action" => "write_page",
                   "title" => "ShouldNotExist",
                   "parent_page_id" => foreign_parent.id,
                   "body" => "x"
                 },
                 ctx
               )

      assert err =~ "not a page in this brain" or err =~ "parent_page_id"

      # No page with that title was created in the first brain.
      {:ok, found} = Brain.find_page_by_title(brain.id, "ShouldNotExist", actor: user)
      assert found == []
    end
  end

  # ---------------------------------------------------------------------------
  # edit_page (string mode)
  # ---------------------------------------------------------------------------

  describe "edit_page action — string mode" do
    test "replaces a unique substring and returns a unified diff",
         %{} do
      %{context: ctx, page: page, user: user} =
        setup_brain_with_page("The quick brown fox jumps")

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "edit_page",
                   "page_id" => page.id,
                   "old_str" => "brown",
                   "new_str" => "red"
                 },
                 ctx
               )

      assert result.action == "edit_page"
      assert result.mode == "string"
      assert result.replacements == 1
      assert result.diff =~ "---"
      assert read_page_body!(page.id, user) == "The quick red fox jumps"
    end

    test "errors when old_str is not present" do
      %{context: ctx, page: page} = setup_brain_with_page("body content")

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "edit_page",
                   "page_id" => page.id,
                   "old_str" => "absent",
                   "new_str" => "x"
                 },
                 ctx
               )

      assert result.error =~ "old_str not found"
      assert result.page_id == page.id
    end

    test "errors on ambiguous match without replace_all and lists line numbers" do
      %{context: ctx, page: page} = setup_brain_with_page("foo\nfoo\nbar")

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "edit_page",
                   "page_id" => page.id,
                   "old_str" => "foo",
                   "new_str" => "qux"
                 },
                 ctx
               )

      assert result.error =~ "2 times"
      assert result.occurrences == 2
      assert result.error =~ "1, 2"
    end

    test "replace_all replaces every occurrence" do
      %{context: ctx, page: page, user: user} = setup_brain_with_page("foo foo foo")

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "edit_page",
                   "page_id" => page.id,
                   "old_str" => "foo",
                   "new_str" => "qux",
                   "replace_all" => true
                 },
                 ctx
               )

      assert result.replacements == 3
      assert read_page_body!(page.id, user) == "qux qux qux"
    end
  end

  # ---------------------------------------------------------------------------
  # edit_page (line-range mode)
  # ---------------------------------------------------------------------------

  describe "edit_page action — line-range mode" do
    test "replaces a range of lines" do
      body = "one\ntwo\nthree\nfour"
      %{context: ctx, page: page, user: user} = setup_brain_with_page(body)

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "edit_page",
                   "page_id" => page.id,
                   "start_line" => 2,
                   "end_line" => 3,
                   "new_content" => "REPLACED"
                 },
                 ctx
               )

      assert result.action == "edit_page"
      assert result.mode == "line_range"
      assert result.lines_replaced == "2-3"
      assert read_page_body!(page.id, user) == "one\nREPLACED\nfour"
    end

    test "pure insertion when end_line == start_line - 1" do
      body = "one\ntwo\nthree"
      %{context: ctx, page: page, user: user} = setup_brain_with_page(body)

      assert {:ok, _result} =
               EditBrain.run(
                 %{
                   "action" => "edit_page",
                   "page_id" => page.id,
                   "start_line" => 2,
                   "end_line" => 1,
                   "new_content" => "INSERTED"
                 },
                 ctx
               )

      assert read_page_body!(page.id, user) == "one\nINSERTED\ntwo\nthree"
    end

    test "pure deletion when new_content is empty" do
      body = "one\ntwo\nthree\nfour"
      %{context: ctx, page: page, user: user} = setup_brain_with_page(body)

      assert {:ok, _result} =
               EditBrain.run(
                 %{
                   "action" => "edit_page",
                   "page_id" => page.id,
                   "start_line" => 2,
                   "end_line" => 3,
                   "new_content" => ""
                 },
                 ctx
               )

      assert read_page_body!(page.id, user) == "one\nfour"
    end

    test "errors when start_line < 1" do
      %{context: ctx, page: page} = setup_brain_with_page("one")

      assert {:ok, %{error: error}} =
               EditBrain.run(
                 %{
                   "action" => "edit_page",
                   "page_id" => page.id,
                   "start_line" => 0,
                   "end_line" => 1,
                   "new_content" => "x"
                 },
                 ctx
               )

      assert error =~ "start_line"
    end

    test "errors when start_line exceeds body length" do
      %{context: ctx, page: page} = setup_brain_with_page("only one\nand two")

      assert {:ok, %{error: error}} =
               EditBrain.run(
                 %{
                   "action" => "edit_page",
                   "page_id" => page.id,
                   "start_line" => 99,
                   "end_line" => 100,
                   "new_content" => "x"
                 },
                 ctx
               )

      assert error =~ "exceeds"
    end

    test "errors when neither string nor line-range params are supplied" do
      %{context: ctx, page: page} = setup_brain_with_page("body")

      assert {:ok, %{error: error}} =
               EditBrain.run(
                 %{"action" => "edit_page", "page_id" => page.id},
                 ctx
               )

      assert error =~ "old_str" or error =~ "start_line"
    end
  end

  # ---------------------------------------------------------------------------
  # multi_edit
  # ---------------------------------------------------------------------------

  describe "multi_edit action" do
    test "applies a sequence of string-mode edits in one save" do
      %{context: ctx, page: page, user: user} =
        setup_brain_with_page("foo\nbar\nbaz")

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "multi_edit",
                   "page_id" => page.id,
                   "edits" => [
                     %{"old_str" => "foo", "new_str" => "FOO"},
                     %{"old_str" => "baz", "new_str" => "BAZ"}
                   ]
                 },
                 ctx
               )

      assert result.action == "multi_edit"
      assert result.edits_applied == 2
      assert read_page_body!(page.id, user) == "FOO\nbar\nBAZ"

      {:ok, updated} = Brain.get_page(page.id, actor: user)
      assert updated.lock_version == page.lock_version + 1
    end

    test "accepts edits passed as a JSON-encoded string (LLM format drift)" do
      %{context: ctx, page: page, user: user} = setup_brain_with_page("foo\nbar\nbaz")

      # Some LLMs stringify the array param instead of sending a real list; the
      # tool must decode it rather than rejecting it (which forced a fallback to
      # slower one-at-a-time edits).
      edits_json =
        Jason.encode!([
          %{"old_str" => "foo", "new_str" => "FOO"},
          %{"old_str" => "baz", "new_str" => "BAZ"}
        ])

      assert {:ok, result} =
               EditBrain.run(
                 %{"action" => "multi_edit", "page_id" => page.id, "edits" => edits_json},
                 ctx
               )

      assert result.action == "multi_edit"
      assert result.edits_applied == 2
      assert read_page_body!(page.id, user) == "FOO\nbar\nBAZ"
    end

    test "later edits operate on the buffer left by earlier edits" do
      %{context: ctx, page: page, user: user} =
        setup_brain_with_page("alpha")

      assert {:ok, _} =
               EditBrain.run(
                 %{
                   "action" => "multi_edit",
                   "page_id" => page.id,
                   "edits" => [
                     %{"old_str" => "alpha", "new_str" => "beta"},
                     %{"old_str" => "beta", "new_str" => "gamma"}
                   ]
                 },
                 ctx
               )

      assert read_page_body!(page.id, user) == "gamma"
    end

    test "supports line-range edits in the batch" do
      %{context: ctx, page: page, user: user} =
        setup_brain_with_page("line 1\nline 2\nline 3")

      assert {:ok, _} =
               EditBrain.run(
                 %{
                   "action" => "multi_edit",
                   "page_id" => page.id,
                   "edits" => [
                     %{
                       "start_line" => 2,
                       "end_line" => 2,
                       "new_content" => "REPLACED"
                     },
                     %{"old_str" => "line 3", "new_str" => "line three"}
                   ]
                 },
                 ctx
               )

      assert read_page_body!(page.id, user) == "line 1\nREPLACED\nline three"
    end

    test "all-or-nothing: a failing edit aborts the whole batch with no body change" do
      %{context: ctx, page: page, user: user} =
        setup_brain_with_page("foo\nbar")

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "multi_edit",
                   "page_id" => page.id,
                   "edits" => [
                     %{"old_str" => "foo", "new_str" => "FOO"},
                     # this one fails: "missing" is not in the buffer
                     %{"old_str" => "missing", "new_str" => "X"}
                   ]
                 },
                 ctx
               )

      assert result.failed_edit_index == 1
      assert result.error =~ "edit #1 failed"
      # Body unchanged.
      assert read_page_body!(page.id, user) == "foo\nbar"

      {:ok, refreshed} = Brain.get_page(page.id, actor: user)
      assert refreshed.lock_version == page.lock_version
    end

    test "errors when page_id is missing" do
      %{context: ctx} = setup_brain_with_page("body")

      assert {:ok, %{error: error}} =
               EditBrain.run(
                 %{"action" => "multi_edit", "edits" => [%{"old_str" => "a", "new_str" => "b"}]},
                 ctx
               )

      assert error =~ "page_id"
    end

    test "errors when edits is empty or missing" do
      %{context: ctx, page: page} = setup_brain_with_page("body")

      assert {:ok, %{error: e1}} =
               EditBrain.run(%{"action" => "multi_edit", "page_id" => page.id}, ctx)

      assert e1 =~ "edits"

      assert {:ok, %{error: e2}} =
               EditBrain.run(
                 %{"action" => "multi_edit", "page_id" => page.id, "edits" => []},
                 ctx
               )

      assert e2 =~ "edits"
    end

    test "rejects an edit that specifies both string and line-range modes" do
      %{context: ctx, page: page} = setup_brain_with_page("body")

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "multi_edit",
                   "page_id" => page.id,
                   "edits" => [
                     %{
                       "old_str" => "body",
                       "new_str" => "B",
                       "start_line" => 1,
                       "end_line" => 1,
                       "new_content" => "X"
                     }
                   ]
                 },
                 ctx
               )

      assert result.failed_edit_index == 0
      assert result.error =~ "both old_str and start_line"
    end

    test "rejects ambiguous string edits unless replace_all is set" do
      %{context: ctx, page: page, user: user} =
        setup_brain_with_page("dup dup")

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "multi_edit",
                   "page_id" => page.id,
                   "edits" => [%{"old_str" => "dup", "new_str" => "X"}]
                 },
                 ctx
               )

      assert result.failed_edit_index == 0
      assert result.error =~ "appears 2 times"
      assert read_page_body!(page.id, user) == "dup dup"

      assert {:ok, ok} =
               EditBrain.run(
                 %{
                   "action" => "multi_edit",
                   "page_id" => page.id,
                   "edits" => [
                     %{"old_str" => "dup", "new_str" => "X", "replace_all" => true}
                   ]
                 },
                 ctx
               )

      assert ok.action == "multi_edit"
      assert read_page_body!(page.id, user) == "X X"
    end
  end

  # ---------------------------------------------------------------------------
  # clear_page
  # ---------------------------------------------------------------------------

  describe "clear_page action" do
    test "resets the body to an empty string" do
      %{context: ctx, page: page, user: user} = setup_brain_with_page("some content")

      assert {:ok, result} =
               EditBrain.run(%{"action" => "clear_page", "page_id" => page.id}, ctx)

      assert result.action == "clear_page"
      assert result.cleared == true
      assert read_page_body!(page.id, user) == ""
    end

    test "errors when page_id is missing" do
      %{context: ctx} = setup_brain_with_page("body")

      assert {:ok, %{error: error}} = EditBrain.run(%{"action" => "clear_page"}, ctx)
      assert error =~ "page_id"
    end
  end

  # ---------------------------------------------------------------------------
  # undo_last_edit
  # ---------------------------------------------------------------------------

  describe "undo_last_edit action" do
    test "restores the previous body after a write_page :replace" do
      %{context: ctx, page: page, user: user} = setup_brain_with_page("v1 content")

      # First edit: v1 → v2
      {:ok, _} =
        EditBrain.run(
          %{
            "action" => "write_page",
            "page_id" => page.id,
            "body" => "v2 content",
            "mode" => "replace"
          },
          ctx
        )

      # Second edit: v2 → v3
      {:ok, _} =
        EditBrain.run(
          %{
            "action" => "write_page",
            "page_id" => page.id,
            "body" => "v3 content",
            "mode" => "replace"
          },
          ctx
        )

      assert read_page_body!(page.id, user) == "v3 content"

      assert {:ok, result} =
               EditBrain.run(%{"action" => "undo_last_edit", "page_id" => page.id}, ctx)

      assert result.action == "undo_last_edit"
      # Restored to v2.
      assert read_page_body!(page.id, user) == "v2 content"
    end

    test "errors when page_id is missing" do
      %{context: ctx} = setup_brain_with_page("body")

      assert {:ok, %{error: error}} = EditBrain.run(%{"action" => "undo_last_edit"}, ctx)
      assert error =~ "page_id"
    end
  end

  # ---------------------------------------------------------------------------
  # rename_page
  # ---------------------------------------------------------------------------

  describe "rename_page action" do
    test "renames the page and echoes current" do
      %{context: ctx, page: page} = setup_brain_with_page("")

      assert {:ok, result} =
               EditBrain.run(
                 %{"action" => "rename_page", "page_id" => page.id, "title" => "Renamed"},
                 ctx
               )

      assert result.action == "rename_page"
      assert result.page_title == "Renamed"
      assert result.current.page_title == "Renamed"
      assert result.hint =~ "Renamed"
    end

    test "errors when title is missing" do
      %{context: ctx, page: page} = setup_brain_with_page("")

      assert {:ok, %{error: error}} =
               EditBrain.run(
                 %{"action" => "rename_page", "page_id" => page.id},
                 ctx
               )

      assert error =~ "title"
    end

    test "errors when page_id is missing" do
      %{context: ctx} = setup_brain_with_page("")

      assert {:ok, %{error: error}} =
               EditBrain.run(
                 %{"action" => "rename_page", "title" => "X"},
                 ctx
               )

      assert error =~ "page_id"
    end
  end

  # ---------------------------------------------------------------------------
  # move_page
  # ---------------------------------------------------------------------------

  describe "move_page action" do
    test "moves a page under a new parent" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, parent} = Brain.create_page(brain.id, %{title: "New Parent"}, actor: user)
      {:ok, child} = Brain.create_page(brain.id, %{title: "Orphan"}, actor: user)

      ctx = context_for(user, brain.id, nil)

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "move_page",
                   "page_id" => child.id,
                   "parent_page_id" => parent.id
                 },
                 ctx
               )

      assert result.action == "move_page"
      assert result.parent_page_id == parent.id
      assert result.depth == 1
    end

    test "moves a page back to root with parent_page_id: nil" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, parent} = Brain.create_page(brain.id, %{title: "P"}, actor: user)

      {:ok, child} =
        Brain.create_page(brain.id, %{title: "Nested", parent_page_id: parent.id}, actor: user)

      ctx = context_for(user, brain.id, nil)

      assert {:ok, result} =
               EditBrain.run(
                 %{
                   "action" => "move_page",
                   "page_id" => child.id,
                   "parent_page_id" => nil
                 },
                 ctx
               )

      assert result.parent_page_id == nil
      assert result.depth == 0
    end

    test "errors when page_id is missing" do
      %{context: ctx} = setup_brain_with_page("")

      assert {:ok, %{error: error}} = EditBrain.run(%{"action" => "move_page"}, ctx)
      assert error =~ "page_id"
    end
  end

  # ---------------------------------------------------------------------------
  # delete_page
  # ---------------------------------------------------------------------------

  describe "delete_page action" do
    test "moves the page to the trash" do
      %{user: user, brain: brain} = setup_brain()
      {:ok, temp} = Brain.create_page(brain.id, %{title: "Temp"}, actor: user)
      ctx = context_for(user, brain.id, temp.id)

      assert {:ok, result} =
               EditBrain.run(%{"action" => "delete_page", "page_id" => temp.id}, ctx)

      assert result.action == "delete_page"
      assert result.hint =~ "trash"
      assert {:error, _} = Brain.get_page(temp.id, actor: user)
    end

    test "errors when page_id is missing" do
      %{context: ctx} = setup_brain_with_page("")

      assert {:ok, %{error: error}} = EditBrain.run(%{"action" => "delete_page"}, ctx)
      assert error =~ "page_id"
    end
  end
end
