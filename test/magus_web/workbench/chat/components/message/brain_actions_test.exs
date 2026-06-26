defmodule MagusWeb.Workbench.Chat.Components.Message.BrainActionsTest do
  @moduledoc """
  Phase C5: the "Add to brain" chat-message buttons now append markdown
  to the open brain pane page's `body` instead of creating typed
  `:message` / `:source` blocks. The same `BodyAppender` helper is used
  by the file picker, drag-drop, and sidebar-link funnels in the brain
  pane.

  These tests exercise the helper directly (the LiveView `handle_event`
  callbacks are thin pass-throughs that load the page + delegate) plus
  cover the version-conflict retry protocol.
  """

  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Brain
  alias Magus.Brain.BodyAppender

  setup do
    user = generate(user()) |> ensure_workspace_plan()
    {:ok, brain} = Brain.create_brain(%{title: "Brain"}, actor: user)
    {:ok, page} = Brain.create_page(brain.id, %{title: "Page"}, actor: user)
    %{user: user, brain: brain, page: page}
  end

  describe "append_message/3" do
    test "appends `[[msg:<id>|<preview>]]` to an empty body", %{user: user, page: page} do
      msg_id = Ash.UUID.generate()

      {:ok, updated} =
        BodyAppender.append_message(
          page,
          %{message_id: msg_id, preview: "Key finding about LLMs"},
          user
        )

      assert updated.body == "[[msg:#{msg_id}|Key finding about LLMs]]"
      assert updated.lock_version == page.lock_version + 1
    end

    test "appends with a blank line separator when body is non-empty",
         %{user: user, page: page} do
      {:ok, page} =
        Brain.update_page_body(page, %{body: "Existing notes", base_version: 0}, actor: user)

      msg_id = Ash.UUID.generate()

      {:ok, updated} =
        BodyAppender.append_message(page, %{message_id: msg_id, preview: "preview"}, user)

      assert updated.body == "Existing notes\n\n[[msg:#{msg_id}|preview]]"
    end

    test "omits the `|<preview>` part when preview is empty or blank",
         %{user: user, page: page} do
      msg_id = Ash.UUID.generate()

      {:ok, updated} =
        BodyAppender.append_message(page, %{message_id: msg_id, preview: ""}, user)

      assert updated.body == "[[msg:#{msg_id}]]"

      msg_id2 = Ash.UUID.generate()
      {:ok, page2} = Brain.create_page(updated.brain_id, %{title: "P2"}, actor: user)

      {:ok, updated2} =
        BodyAppender.append_message(page2, %{message_id: msg_id2, preview: nil}, user)

      assert updated2.body == "[[msg:#{msg_id2}]]"
    end

    test "strips pipes and brackets from preview so the wikilink stays valid",
         %{user: user, page: page} do
      msg_id = Ash.UUID.generate()

      {:ok, updated} =
        BodyAppender.append_message(
          page,
          %{message_id: msg_id, preview: "a|b[c]d"},
          user
        )

      assert updated.body == "[[msg:#{msg_id}|a b c d]]"
    end

    test "collapses newlines in preview so the JS wikilink regex can match",
         %{user: user, page: page} do
      # The JS markdown parser uses `[[([^\]\n]+)]]` which rejects newlines.
      # A multi-line preview must be flattened to one line or the editor
      # renders the literal `[[msg:...]]` text instead of a message card.
      msg_id = Ash.UUID.generate()

      {:ok, updated} =
        BodyAppender.append_message(
          page,
          %{message_id: msg_id, preview: "Salut !\n\nEt toi ?"},
          user
        )

      assert updated.body == "[[msg:#{msg_id}|Salut ! Et toi ?]]"
      refute updated.body =~ "\n", "preview must not contain newlines inside [[ ]]"
    end
  end

  describe "append_source/3" do
    test "appends a ```source fence with url + title + source_type",
         %{user: user, page: page} do
      {:ok, updated} =
        BodyAppender.append_source(
          page,
          %{url: "https://arxiv.org/abs/2001.08361", title: "Scaling Laws", source_type: "web"},
          user
        )

      # URLs contain `:` which is a YAML reserved scalar character, so
      # the value is emitted quoted. This matches `BlockSerializer`'s
      # round-trip behavior (see markdown_round_trip_test.exs).
      assert updated.body == """
             ```source
             url: "https://arxiv.org/abs/2001.08361"
             title: Scaling Laws
             source_type: web
             ```\
             """
    end

    test "defaults title to the URL when missing", %{user: user, page: page} do
      {:ok, updated} =
        BodyAppender.append_source(page, %{url: "https://example.com"}, user)

      assert updated.body =~ ~s(url: "https://example.com")
      assert updated.body =~ ~s(title: "https://example.com")
      assert updated.body =~ "source_type: web"
    end

    test "is a silent no-op when url is blank", %{user: user, page: page} do
      assert {:error, :empty} = BodyAppender.append_source(page, %{url: ""}, user)
      assert {:error, :empty} = BodyAppender.append_source(page, %{url: nil}, user)
    end
  end

  describe "append_file_by_id/4" do
    test "appends `[📎 caption](magus://file/<id>)` for non-image files",
         %{user: user, page: page} do
      file = generate(file(type: :document, actor: user))

      {:ok, updated} = BodyAppender.append_file_by_id(page, file.id, "Spec PDF", user)

      assert updated.body == "[📎 Spec PDF](magus://file/#{file.id})"
    end

    test "appends `![caption](magus://image/<id>)` for image files",
         %{user: user, page: page} do
      file =
        generate(file(type: :image, mime_type: "image/png", name: "shot.png", actor: user))

      {:ok, updated} = BodyAppender.append_file_by_id(page, file.id, "Screenshot", user)

      assert updated.body == "![Screenshot](magus://image/#{file.id})"
    end

    test "returns `{:error, :file_not_found}` for an unknown id",
         %{user: user, page: page} do
      assert {:error, :file_not_found} =
               BodyAppender.append_file_by_id(page, Ash.UUID.generate(), "x", user)
    end
  end

  describe "version-conflict retry" do
    test "retries once when another writer bumped lock_version between read and save",
         %{user: user, page: page} do
      # Simulate a stale page handle: an out-of-band write bumps the
      # page's lock_version while our caller still holds the original
      # (lock_version: 0).
      {:ok, _bumped} =
        Brain.update_page_body(
          page,
          %{body: "concurrent agent edit", base_version: 0},
          actor: user
        )

      msg_id = Ash.UUID.generate()

      # `page` still has lock_version: 0 — the first save inside
      # `append_message` will hit `VersionConflict`. The retry path
      # should pick up `current_body = "concurrent agent edit"` and
      # `current_version = 1` from the conflict and succeed on the
      # second attempt.
      assert {:ok, updated} =
               BodyAppender.append_message(
                 page,
                 %{message_id: msg_id, preview: "after retry"},
                 user
               )

      assert updated.body == "concurrent agent edit\n\n[[msg:#{msg_id}|after retry]]"
      # Original page was at 0, one concurrent edit + one retried save = 2.
      assert updated.lock_version == 2
    end
  end
end
