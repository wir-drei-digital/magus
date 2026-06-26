defmodule Magus.Agents.Context.CompanionPreambleTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Context.CompanionPreamble

  test "returns empty string when conversation is not a companion" do
    user = generate(user())
    {:ok, conv} = Magus.Chat.create_conversation(%{title: "X"}, actor: user)

    assert "" = CompanionPreamble.build(%{conversation_id: conv.id, user: user})
  end

  test "returns empty string when conversation_id missing" do
    assert "" = CompanionPreamble.build(%{})
  end

  test "returns templated section for a file companion" do
    user = generate(user())
    ws = generate(workspace(actor: user))
    ensure_workspace_plan(user)

    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "ash-framework.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "#{user.id}/#{Ash.UUIDv7.generate()}.pdf",
          workspace_id: ws.id
        },
        actor: user
      )

    {:ok, conv} =
      Magus.Chat.find_or_create_companion_conversation(:file, file.id, actor: user)

    text = CompanionPreamble.build(%{conversation_id: conv.id, user: user})

    assert text =~ "Active companion context"
    assert text =~ "ash-framework.pdf"
    assert text =~ to_string(file.id)
    assert text =~ "search_files"
  end

  test "returns templated section for a brain page companion" do
    user = generate(user())
    {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Notes"}, actor: user)

    {:ok, conv} =
      Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

    text = CompanionPreamble.build(%{conversation_id: conv.id, user: user})

    assert text =~ "Active companion context"
    assert text =~ "Notes"
    assert text =~ to_string(page.id)
    assert text =~ "read_brain"

    # `read_page` lives on the read_brain tool, NOT edit_brain. Telling the
    # agent to call edit_brain(action: "read_page") errors with
    # "Unknown action 'read_page'" and forces a retry, so the preamble must
    # attribute it to read_brain.
    refute text =~ ~s|navigate_brain(action: "read_page"|
    refute text =~ ~s|edit_brain(action: "read_page"|
    assert text =~ ~s|read_brain(action: "read_page"|
  end

  test "inlines the full page body so no read_page probe is needed" do
    user = generate(user())
    {:ok, brain} = Magus.Brain.create_brain(%{title: "Research"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Scaling Laws"}, actor: user)

    {:ok, _page} =
      Magus.Brain.update_page_body(
        page,
        %{body: "Power law scaling is fundamental to model performance.", base_version: 0},
        actor: user
      )

    {:ok, conv} =
      Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

    text = CompanionPreamble.build(%{conversation_id: conv.id, user: user})

    # Full body is inlined under a "Current page" heading.
    assert text =~ "Power law scaling is fundamental to model performance."
    assert text =~ "### Current page: Scaling Laws"
    # The agent is told it does NOT need to call read_brain to read this page.
    assert text =~ "do NOT need to call"
    assert text =~ "brain_id:"
  end

  test "inlines the brain page tree with the active page marked" do
    user = generate(user())
    {:ok, brain} = Magus.Brain.create_brain(%{title: "Tree Brain"}, actor: user)
    {:ok, parent} = Magus.Brain.create_page(brain.id, %{title: "Parent"}, actor: user)

    {:ok, active} =
      Magus.Brain.create_page(brain.id, %{title: "Active Page", parent_page_id: parent.id},
        actor: user
      )

    {:ok, sibling} =
      Magus.Brain.create_page(brain.id, %{title: "Sibling Page", parent_page_id: parent.id},
        actor: user
      )

    {:ok, conv} =
      Magus.Chat.find_or_create_companion_conversation(:brain_page, active.id, actor: user)

    text = CompanionPreamble.build(%{conversation_id: conv.id, user: user})

    assert text =~ "### Page tree"
    assert text =~ "Parent (id: #{parent.id})"
    # active page carries the [THIS PAGE] marker and its id
    assert text =~ ~r/Active Page \[THIS PAGE\] \(id: #{active.id}\)/
    assert text =~ "Sibling Page (id: #{sibling.id})"
  end

  test "surfaces the available brains list with brain ids" do
    user = generate(user())
    {:ok, brain} = Magus.Brain.create_brain(%{title: "Companion Brain"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Notes"}, actor: user)

    {:ok, conv} =
      Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

    text = CompanionPreamble.build(%{conversation_id: conv.id, user: user})

    assert text =~ "### Available brains"
    assert text =~ "brain_id: #{brain.id}"
  end

  test "truncates an overly long page body with a truncation note" do
    user = generate(user())
    {:ok, brain} = Magus.Brain.create_brain(%{title: "Big"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Long"}, actor: user)

    long_body = String.duplicate("abcdefghij", 3_000)

    {:ok, _page} =
      Magus.Brain.update_page_body(page, %{body: long_body, base_version: 0}, actor: user)

    {:ok, conv} =
      Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

    text = CompanionPreamble.build(%{conversation_id: conv.id, user: user})

    # The 30k-char body must not appear verbatim; a truncation note is added.
    refute text =~ long_body
    assert text =~ "truncated"
  end

  test "appends file references summary when active page has file blocks" do
    user = generate(user()) |> ensure_workspace_plan()
    {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "spec.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1024,
          file_path: "tmp/spec.pdf",
          workspace_id: nil
        },
        actor: user
      )

    {:ok, _page} =
      Magus.Brain.update_page_body(
        page,
        %{body: "[📎 spec](magus://file/#{file.id})", base_version: 0},
        actor: user
      )

    {:ok, conv} =
      Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

    preamble = CompanionPreamble.build(%{conversation_id: conv.id, user: user})

    assert preamble =~ "spec.pdf"
    assert preamble =~ "1 file:"
    assert preamble =~ "This page references"
  end

  test "no file summary when active page has no file references" do
    user = generate(user()) |> ensure_workspace_plan()
    {:ok, brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)
    {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "P"}, actor: user)

    {:ok, _page} =
      Magus.Brain.update_page_body(
        page,
        %{body: "Just text, no attachments.", base_version: 0},
        actor: user
      )

    {:ok, conv} =
      Magus.Chat.find_or_create_companion_conversation(:brain_page, page.id, actor: user)

    preamble = CompanionPreamble.build(%{conversation_id: conv.id, user: user})

    refute preamble =~ "references"
  end
end
