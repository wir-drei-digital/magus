defmodule MagusWeb.Live.PresenceSurfacesTest do
  @moduledoc """
  LiveView integration tests verifying that the presence indicator renders
  a peer's initial when a second viewer joins the same resource.

  Each describe block covers one of the four surfaces that call
  `Magus.Presence.track/3`:

    1. ConversationView  - :conversation topic
    2. BrainPageView     - :page topic
    3. DraftCompanion    - :draft topic
    4. SpreadsheetCompanion - :spreadsheet topic

  Two LiveView processes are mounted in the same test process. Because
  Phoenix.Presence broadcasts are asynchronous (via PubSub), we poll
  with `eventually/1` rather than asserting immediately.
  """
  use MagusWeb.LiveViewCase, async: false

  import Phoenix.LiveViewTest
  import Magus.Generators

  alias MagusWeb.Workbench.Resources.ConversationView
  alias MagusWeb.Workbench.Resources.BrainPageView
  alias MagusWeb.Workbench.Resources.Companions.DraftCompanion
  alias MagusWeb.Workbench.Resources.Companions.SpreadsheetCompanion

  @ai_agent %Magus.Agents.Support.AiAgent{}

  # ---------------------------------------------------------------------------
  # Surface 1: ConversationView
  # ---------------------------------------------------------------------------

  describe "conversation header presence" do
    setup do
      owner = generate(user())
      peer = generate(user())
      ensure_workspace_plan(owner)
      ws = generate(workspace(actor: owner))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "Shared conv", workspace_id: ws.id},
          actor: owner
        )

      # Enable multiplayer so peer can be granted access
      {:ok, conv} = Magus.Chat.enable_multiplayer(conv, actor: owner)

      # Grant peer viewer access via a workspace grant (simplest path)
      Magus.Workspaces.grant_access!(
        %{
          resource_type: :conversation,
          resource_id: conv.id,
          grantee_type: :user,
          grantee_id: peer.id,
          role: :viewer
        },
        actor: owner
      )

      %{owner: owner, peer: peer, conv: conv}
    end

    test "second viewer's initial appears in first viewer's header",
         %{owner: owner, peer: peer, conv: conv} do
      # Mount owner first
      {:ok, view1, _html} =
        live_isolated(build_conn(), ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => owner.id,
            "tab_id" => "tab-owner"
          }
        )

      # Mount peer - this triggers Presence.track which broadcasts presence_diff
      {:ok, _view2, _html} =
        live_isolated(build_conn(), ConversationView,
          session: %{
            "conversation_id" => conv.id,
            "user_id" => peer.id,
            "tab_id" => "tab-peer"
          }
        )

      assert eventually(fn -> render(view1) =~ peer_initial(peer) end),
             "Expected peer's initial #{peer_initial(peer)} to appear in owner's view"
    end
  end

  # ---------------------------------------------------------------------------
  # Surface 2: BrainPageView
  # ---------------------------------------------------------------------------

  describe "brain page header presence" do
    setup do
      owner = generate(user())
      peer = generate(user())

      {:ok, brain} = Magus.Brain.create_brain(%{title: "Shared brain"}, actor: owner)
      {:ok, page} = Magus.Brain.create_page(brain.id, %{title: "Collab page"}, actor: owner)

      # Grant peer access to the brain page via a user grant
      Magus.Workspaces.grant_access!(
        %{
          resource_type: :brain,
          resource_id: brain.id,
          grantee_type: :user,
          grantee_id: peer.id,
          role: :viewer
        },
        actor: owner
      )

      %{owner: owner, peer: peer, page: page, brain: brain}
    end

    test "second viewer's initial appears in first viewer's page header",
         %{owner: owner, peer: peer, page: page} do
      {:ok, view1, _html} =
        live_isolated(build_conn(), BrainPageView,
          session: %{
            "page_id" => page.id,
            "user_id" => owner.id,
            "tab_id" => "tab-owner",
            "role" => "primary"
          }
        )

      {:ok, _view2, _html} =
        live_isolated(build_conn(), BrainPageView,
          session: %{
            "page_id" => page.id,
            "user_id" => peer.id,
            "tab_id" => "tab-peer",
            "role" => "primary"
          }
        )

      assert eventually(fn -> render(view1) =~ peer_initial(peer) end),
             "Expected peer's initial #{peer_initial(peer)} to appear in owner's brain page view"
    end
  end

  # ---------------------------------------------------------------------------
  # Surface 3: DraftCompanion
  # ---------------------------------------------------------------------------

  describe "draft companion presence" do
    setup do
      owner = generate(user())
      peer = generate(user())
      ensure_workspace_plan(owner)
      ws = generate(workspace(actor: owner))

      {:ok, conv} =
        Magus.Chat.create_conversation(
          %{title: "Draft conv", workspace_id: ws.id},
          actor: owner
        )

      {:ok, conv} = Magus.Chat.enable_multiplayer(conv, actor: owner)

      Magus.Workspaces.grant_access!(
        %{
          resource_type: :conversation,
          resource_id: conv.id,
          grantee_type: :user,
          grantee_id: peer.id,
          role: :viewer
        },
        actor: owner
      )

      {:ok, draft} =
        Magus.Drafts.create_draft(conv.id, "Collab draft", "Hello world", owner.id, actor: owner)

      %{owner: owner, peer: peer, conv: conv, draft: draft}
    end

    test "second viewer's initial appears in first viewer's draft companion",
         %{owner: owner, peer: peer, conv: conv, draft: draft} do
      {:ok, view1, _html} =
        live_isolated(build_conn(), DraftCompanion,
          session: %{
            "draft_id" => draft.id,
            "conversation_id" => conv.id,
            "user_id" => owner.id,
            "tab_id" => "tab-owner"
          }
        )

      {:ok, _view2, _html} =
        live_isolated(build_conn(), DraftCompanion,
          session: %{
            "draft_id" => draft.id,
            "conversation_id" => conv.id,
            "user_id" => peer.id,
            "tab_id" => "tab-peer"
          }
        )

      assert eventually(fn -> render(view1) =~ peer_initial(peer) end),
             "Expected peer's initial #{peer_initial(peer)} to appear in owner's draft companion"
    end
  end

  # ---------------------------------------------------------------------------
  # Surface 4: SpreadsheetCompanion
  # ---------------------------------------------------------------------------

  describe "spreadsheet companion presence" do
    setup do
      owner = generate(user())
      peer = generate(user())

      binary =
        File.read!(
          Path.join(
            __DIR__,
            "../../support/fixtures/sample.xlsx"
          )
        )

      {:ok, file} =
        Magus.Files.create_file_from_content(
          %{
            name: "collab.xlsx",
            type: :document,
            mime_type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            user_id: owner.id,
            content: binary
          },
          actor: @ai_agent
        )

      # Grant peer access to the file
      Magus.Workspaces.grant_access!(
        %{
          resource_type: :file,
          resource_id: file.id,
          grantee_type: :user,
          grantee_id: peer.id,
          role: :viewer
        },
        actor: owner
      )

      %{owner: owner, peer: peer, xlsx_file: file}
    end

    test "second viewer's initial appears in first viewer's spreadsheet companion",
         %{owner: owner, peer: peer, xlsx_file: xlsx_file} do
      {:ok, view1, _html} =
        live_isolated(build_conn(), SpreadsheetCompanion,
          session: %{
            "file_id" => xlsx_file.id,
            "user_id" => owner.id,
            "tab_id" => "tab-owner"
          }
        )

      {:ok, _view2, _html} =
        live_isolated(build_conn(), SpreadsheetCompanion,
          session: %{
            "file_id" => xlsx_file.id,
            "user_id" => peer.id,
            "tab_id" => "tab-peer"
          }
        )

      assert eventually(fn -> render(view1) =~ peer_initial(peer) end),
             "Expected peer's initial #{peer_initial(peer)} to appear in owner's spreadsheet companion"
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp peer_initial(user) do
    name = user.name || user.email
    name |> String.first() |> String.upcase()
  end

  # Polls every 50 ms up to `timeout_ms`. Returns true if the function ever
  # returns truthy; returns false on timeout (test assertion handles the fail).
  defp eventually(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(50)
        do_eventually(fun, deadline)
    end
  end
end
