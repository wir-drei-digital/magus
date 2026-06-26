defmodule MagusWeb.Workbench.Tab.LabelResolverTest do
  use MagusWeb.LiveViewCase, async: false
  use Gettext, backend: MagusWeb.Gettext

  alias MagusWeb.Workbench.Tab.LabelResolver

  describe "label_for/1" do
    test "uses label when present on the tab" do
      tab = %{"primary" => %{"type" => "conversation", "id" => "x"}, "label" => "My chat"}
      assert LabelResolver.label_for(tab) == "My chat"
    end

    test "returns fallback when label missing" do
      tab = %{"primary" => %{"type" => "conversation", "id" => "x"}}
      assert LabelResolver.label_for(tab) == "Untitled"
    end

    test "returns fallback when label is empty string" do
      tab = %{"primary" => %{"type" => "conversation", "id" => "x"}, "label" => ""}
      assert LabelResolver.label_for(tab) == "Untitled"
    end
  end

  describe "icon_for/1" do
    test "conversation → message icon" do
      assert LabelResolver.icon_for(%{"primary" => %{"type" => "conversation", "id" => "x"}}) ==
               "lucide-message-square"
    end

    test "brain_page → file-text icon" do
      assert LabelResolver.icon_for(%{"primary" => %{"type" => "brain_page", "id" => "x"}}) ==
               "lucide-file-text"
    end

    test "unknown type → generic file icon" do
      assert LabelResolver.icon_for(%{"primary" => %{"type" => "other", "id" => "x"}}) ==
               "lucide-file"
    end

    test "icon_for/1 returns lucide-file for file tabs" do
      assert MagusWeb.Workbench.Tab.LabelResolver.icon_for(%{
               "primary" => %{"type" => "file", "id" => "x"}
             }) == "lucide-file"
    end
  end

  describe "companion_label_for/2" do
    alias MagusWeb.Workbench.Tab.LabelResolver

    test "draft uses the draft title when present" do
      user = generate(user())

      {:ok, conv} =
        Magus.Chat.create_conversation(%{title: "C"}, actor: user)

      {:ok, draft} =
        Magus.Drafts.create_draft(conv.id, "Project plan", "...", user.id, actor: user)

      spec = %{"type" => "draft", "id" => draft.id}
      assert LabelResolver.companion_label_for(spec, user) == "Project plan"
    end

    test "draft falls back to \"Draft\" when title is nil or resource missing" do
      user = generate(user())
      spec = %{"type" => "draft", "id" => Ecto.UUID.generate()}
      assert LabelResolver.companion_label_for(spec, user) == "Draft"
    end

    test "thread uses the thread conversation title" do
      user = generate(user())

      {:ok, parent} =
        Magus.Chat.create_conversation(%{title: "Parent"}, actor: user)

      {:ok, msg} =
        Magus.Chat.create_message(
          %{conversation_id: parent.id, text: "branch here"},
          actor: user
        )

      {:ok, thread} =
        Magus.Chat.create_thread(
          %{parent_conversation_id: parent.id, branched_at_message_id: msg.id},
          actor: user
        )

      spec = %{"type" => "thread", "id" => thread.id}
      expected = thread.title || "Thread"
      assert LabelResolver.companion_label_for(spec, user) == expected
    end

    test "service is the static label \"Service\"" do
      user = generate(user())
      spec = %{"type" => "service", "id" => Ecto.UUID.generate()}
      assert LabelResolver.companion_label_for(spec, user) == "Service"
    end

    test "pdf uses the spec's name field" do
      user = generate(user())
      spec = %{"type" => "pdf", "id" => "f1", "name" => "report.pdf", "url" => "/x"}
      assert LabelResolver.companion_label_for(spec, user) == "report.pdf"
    end

    test "pdf falls back to \"PDF\" when name is missing" do
      user = generate(user())
      spec = %{"type" => "pdf", "id" => "f1"}
      assert LabelResolver.companion_label_for(spec, user) == "PDF"
    end

    test "brain_page uses the page title" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      {:ok, brain} = Magus.Brain.create_brain(%{title: "B", workspace_id: ws.id}, actor: user)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Notes"}, actor: user)

      spec = %{"type" => "brain_page", "id" => page.id}
      assert LabelResolver.companion_label_for(spec, user) == "Notes"
    end

    test "brain_page falls back to \"Brain page\" when missing" do
      user = generate(user())
      spec = %{"type" => "brain_page", "id" => Ecto.UUID.generate()}
      assert LabelResolver.companion_label_for(spec, user) == "Brain page"
    end

    test "unknown type returns \"Companion\"" do
      user = generate(user())
      spec = %{"type" => "made_up", "id" => "x"}
      assert LabelResolver.companion_label_for(spec, user) == "Companion"
    end

    test "nil actor falls back to type-specific static label" do
      assert LabelResolver.companion_label_for(
               %{"type" => "draft", "id" => Ecto.UUID.generate()},
               nil
             ) == "Draft"

      assert LabelResolver.companion_label_for(
               %{"type" => "thread", "id" => Ecto.UUID.generate()},
               nil
             ) == "Thread"

      assert LabelResolver.companion_label_for(
               %{"type" => "brain_page", "id" => Ecto.UUID.generate()},
               nil
             ) == "Brain page"
    end
  end

  describe "companion_icon_for/1" do
    alias MagusWeb.Workbench.Tab.LabelResolver

    test "icon per type" do
      assert LabelResolver.companion_icon_for(%{"type" => "draft"}) == "lucide-pencil-line"
      assert LabelResolver.companion_icon_for(%{"type" => "thread"}) == "lucide-git-branch"
      assert LabelResolver.companion_icon_for(%{"type" => "service"}) == "lucide-globe"
      assert LabelResolver.companion_icon_for(%{"type" => "pdf"}) == "lucide-file-text"
      assert LabelResolver.companion_icon_for(%{"type" => "brain_page"}) == "lucide-file-text"
      assert LabelResolver.companion_icon_for(%{"type" => "?"}) == "lucide-square"
    end
  end

  describe "label_for_primary/2" do
    test "returns nil for unknown primaries" do
      assert LabelResolver.label_for_primary(%{"type" => "what", "id" => "x"}, nil) == nil
    end

    test "agent new yields New agent" do
      assert LabelResolver.label_for_primary(%{"type" => "agent", "id" => "new"}, nil) ==
               "New agent"
    end

    test "prompt new yields New prompt" do
      assert LabelResolver.label_for_primary(%{"type" => "prompt", "id" => "new"}, nil) ==
               "New prompt"
    end

    test "file_browser my_files returns gettext label" do
      assert LabelResolver.label_for_primary(
               %{"type" => "file_browser", "scope" => "my_files"},
               nil
             ) == gettext("My Files")
    end

    test "file_browser shared returns gettext label" do
      assert LabelResolver.label_for_primary(
               %{"type" => "file_browser", "scope" => "shared"},
               nil
             ) == gettext("Shared with me")
    end

    test "file_browser folder falls back to gettext when lookup fails" do
      user = generate(user())

      assert LabelResolver.label_for_primary(
               %{"type" => "file_browser", "scope" => "folder", "id" => Ecto.UUID.generate()},
               user
             ) == gettext("Folder")
    end

    test "conversation new yields New chat" do
      assert LabelResolver.label_for_primary(%{"type" => "conversation", "id" => "new"}, nil) ==
               "New chat"
    end
  end
end
