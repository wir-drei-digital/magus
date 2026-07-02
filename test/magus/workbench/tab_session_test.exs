defmodule Magus.Workbench.TabSessionTest do
  use Magus.ResourceCase, async: true

  alias Magus.Workbench

  describe "get_or_create_tab_session/3" do
    test "creates a new session with defaults when none exists" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, session} = Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)

      assert session.user_id == user.id
      assert session.workspace_id == ws.id
      assert session.mode == :chat
      assert session.nav_filter == :all
      assert session.tabs == []
      assert is_nil(session.active_tab_id)
    end

    test "returns existing session when one exists" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      {:ok, first} = Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)
      {:ok, second} = Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)

      assert first.id == second.id
    end

    test "sessions are scoped per workspace" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws1 = generate(workspace(actor: user))
      ws2 = generate(workspace(actor: user))

      {:ok, s1} = Workbench.get_or_create_tab_session(user.id, ws1.id, actor: user)
      {:ok, s2} = Workbench.get_or_create_tab_session(user.id, ws2.id, actor: user)

      refute s1.id == s2.id
    end

    test "creates a personal-scope session when workspace_id is nil" do
      user = generate(user())

      {:ok, session} = Workbench.get_or_create_tab_session(user.id, nil, actor: user)

      assert session.user_id == user.id
      assert is_nil(session.workspace_id)
    end

    test "nil-workspace sessions deduplicate across calls" do
      user = generate(user())

      {:ok, s1} = Workbench.get_or_create_tab_session(user.id, nil, actor: user)
      {:ok, s2} = Workbench.get_or_create_tab_session(user.id, nil, actor: user)

      assert s1.id == s2.id
    end
  end

  describe "set_mode/2" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      {:ok, session} = Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)
      %{user: user, session: session}
    end

    test "updates the mode", %{user: user, session: session} do
      {:ok, updated} = Workbench.set_tab_session_mode(session, :brain, actor: user)
      assert updated.mode == :brain
    end

    test "accepts :library", %{user: user, session: session} do
      {:ok, updated} = Workbench.set_tab_session_mode(session, :library, actor: user)
      assert updated.mode == :library
    end

    test "rejects unknown modes", %{user: user, session: session} do
      assert {:error, _} = Workbench.set_tab_session_mode(session, :bogus, actor: user)
    end
  end

  describe "set_nav_filter/2" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      {:ok, session} = Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)
      %{user: user, session: session}
    end

    test "updates the filter", %{user: user, session: session} do
      {:ok, updated} = Workbench.set_tab_session_nav_filter(session, :shared, actor: user)
      assert updated.nav_filter == :shared
    end
  end

  describe "open_tab/3" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      {:ok, session} = Magus.Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)
      %{user: user, session: session}
    end

    test "appends a new tab and sets it active", %{user: user, session: session} do
      primary = %{"type" => "conversation", "id" => Ecto.UUID.generate()}

      {:ok, updated} = Magus.Workbench.open_workbench_tab(session, primary, actor: user)

      assert [tab] = updated.tabs
      assert tab["primary"] == primary
      assert is_binary(tab["id"])
      assert is_nil(tab["companion"])
      assert updated.active_tab_id == tab["id"]
    end

    test "dedupes: opening a resource that is already a tab activates existing",
         %{user: user, session: session} do
      primary = %{"type" => "conversation", "id" => Ecto.UUID.generate()}

      {:ok, s1} = Magus.Workbench.open_workbench_tab(session, primary, actor: user)
      {:ok, s2} = Magus.Workbench.open_workbench_tab(s1, primary, actor: user)

      assert length(s2.tabs) == 1
      assert s2.active_tab_id == s1.active_tab_id
    end

    test "appends a second distinct tab", %{user: user, session: session} do
      a = %{"type" => "conversation", "id" => Ecto.UUID.generate()}
      b = %{"type" => "brain_page", "id" => Ecto.UUID.generate()}

      {:ok, s1} = Magus.Workbench.open_workbench_tab(session, a, actor: user)
      {:ok, s2} = Magus.Workbench.open_workbench_tab(s1, b, actor: user)

      assert length(s2.tabs) == 2
      assert s2.active_tab_id == Enum.at(s2.tabs, 1)["id"]
    end

    test "stores a label when provided", %{user: user, session: session} do
      primary = %{"type" => "conversation", "id" => Ecto.UUID.generate()}

      {:ok, updated} =
        Magus.Workbench.open_workbench_tab(session, primary, %{label: "My conversation title"},
          actor: user
        )

      assert [tab] = updated.tabs
      assert tab["label"] == "My conversation title"
    end

    test "leaves label nil when not provided", %{user: user, session: session} do
      primary = %{"type" => "conversation", "id" => Ecto.UUID.generate()}

      {:ok, updated} = Magus.Workbench.open_workbench_tab(session, primary, actor: user)

      assert [tab] = updated.tabs
      assert is_nil(tab["label"])
    end

    test "updates label on already-open tab when different label provided",
         %{user: user, session: session} do
      primary = %{"type" => "conversation", "id" => Ecto.UUID.generate()}

      {:ok, s1} =
        Magus.Workbench.open_workbench_tab(session, primary, %{label: "Old"}, actor: user)

      {:ok, s2} =
        Magus.Workbench.open_workbench_tab(s1, primary, %{label: "New"}, actor: user)

      assert [tab] = s2.tabs
      assert tab["label"] == "New"
    end

    test "single: true trims to just the newly opened tab (tabs-disabled shell)",
         %{user: user, session: session} do
      a = %{"type" => "conversation", "id" => Ecto.UUID.generate()}
      b = %{"type" => "brain_page", "id" => Ecto.UUID.generate()}

      {:ok, s1} = Magus.Workbench.open_workbench_tab(session, a, actor: user)
      {:ok, s2} = Magus.Workbench.open_workbench_tab(s1, b, actor: user)
      assert length(s2.tabs) == 2

      c = %{"type" => "conversation", "id" => Ecto.UUID.generate()}
      {:ok, s3} = Magus.Workbench.open_workbench_tab(s2, c, %{single: true}, actor: user)

      assert [tab] = s3.tabs
      assert tab["primary"] == c
      assert s3.active_tab_id == tab["id"]
    end

    test "single: true activates an existing tab and drops the rest",
         %{user: user, session: session} do
      a = %{"type" => "conversation", "id" => Ecto.UUID.generate()}
      b = %{"type" => "brain_page", "id" => Ecto.UUID.generate()}

      {:ok, s1} = Magus.Workbench.open_workbench_tab(session, a, actor: user)
      {:ok, s2} = Magus.Workbench.open_workbench_tab(s1, b, actor: user)

      {:ok, s3} = Magus.Workbench.open_workbench_tab(s2, a, %{single: true}, actor: user)

      assert [tab] = s3.tabs
      assert tab["primary"] == a
      assert s3.active_tab_id == tab["id"]
    end
  end

  describe "activate_tab/3" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      {:ok, s0} = Magus.Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)

      {:ok, s1} =
        Magus.Workbench.open_workbench_tab(
          s0,
          %{"type" => "conversation", "id" => Ecto.UUID.generate()},
          actor: user
        )

      {:ok, s2} =
        Magus.Workbench.open_workbench_tab(
          s1,
          %{"type" => "conversation", "id" => Ecto.UUID.generate()},
          actor: user
        )

      %{user: user, session: s2}
    end

    test "activates an existing tab by id", %{user: user, session: session} do
      target_id = Enum.at(session.tabs, 0)["id"]
      {:ok, updated} = Magus.Workbench.activate_workbench_tab(session, target_id, actor: user)
      assert updated.active_tab_id == target_id
    end

    test "rejects unknown tab ids", %{user: user, session: session} do
      assert {:error, _} =
               Magus.Workbench.activate_workbench_tab(session, "tab_unknown", actor: user)
    end
  end

  describe "close_tab/3" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      {:ok, s0} = Magus.Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)

      {:ok, s1} =
        Magus.Workbench.open_workbench_tab(
          s0,
          %{"type" => "conversation", "id" => Ecto.UUID.generate()},
          actor: user
        )

      {:ok, s2} =
        Magus.Workbench.open_workbench_tab(
          s1,
          %{"type" => "conversation", "id" => Ecto.UUID.generate()},
          actor: user
        )

      %{user: user, session: s2}
    end

    test "removes a non-active tab, leaves active unchanged",
         %{user: user, session: session} do
      first_id = Enum.at(session.tabs, 0)["id"]
      active = session.active_tab_id
      {:ok, updated} = Magus.Workbench.close_workbench_tab(session, first_id, actor: user)
      assert length(updated.tabs) == 1
      assert updated.active_tab_id == active
    end

    test "removing active shifts to right neighbor when available",
         %{user: user, session: session} do
      first_id = Enum.at(session.tabs, 0)["id"]
      second_id = Enum.at(session.tabs, 1)["id"]
      {:ok, session} = Magus.Workbench.activate_workbench_tab(session, first_id, actor: user)
      {:ok, updated} = Magus.Workbench.close_workbench_tab(session, first_id, actor: user)
      assert updated.active_tab_id == second_id
    end

    test "removing active when only one tab results in nil active",
         %{user: user, session: session} do
      [first_tab, second_tab] = session.tabs
      {:ok, session} = Magus.Workbench.close_workbench_tab(session, first_tab["id"], actor: user)
      {:ok, session} = Magus.Workbench.close_workbench_tab(session, second_tab["id"], actor: user)

      assert session.tabs == []
      assert is_nil(session.active_tab_id)
    end
  end

  describe "set_companion/3" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      {:ok, s0} = Magus.Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)

      {:ok, s1} =
        Magus.Workbench.open_workbench_tab(
          s0,
          %{"type" => "conversation", "id" => Ecto.UUID.generate()},
          actor: user
        )

      %{user: user, session: s1, tab_id: s1.active_tab_id}
    end

    test "sets companion on a specific tab",
         %{user: user, session: session, tab_id: tab_id} do
      companion = %{"type" => "draft", "id" => Ecto.UUID.generate()}

      {:ok, updated} =
        Magus.Workbench.set_workbench_companion(session, tab_id, companion, actor: user)

      tab = Enum.find(updated.tabs, fn t -> t["id"] == tab_id end)
      assert tab["companion"] == companion
    end

    test "clears companion when nil passed",
         %{user: user, session: session, tab_id: tab_id} do
      {:ok, session} =
        Magus.Workbench.set_workbench_companion(
          session,
          tab_id,
          %{"type" => "draft", "id" => Ecto.UUID.generate()},
          actor: user
        )

      {:ok, updated} = Magus.Workbench.set_workbench_companion(session, tab_id, nil, actor: user)

      tab = Enum.find(updated.tabs, fn t -> t["id"] == tab_id end)
      assert is_nil(tab["companion"])
    end
  end

  describe "reorder_tabs/3" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))
      {:ok, s0} = Magus.Workbench.get_or_create_tab_session(user.id, ws.id, actor: user)

      {:ok, s1} =
        Magus.Workbench.open_workbench_tab(
          s0,
          %{"type" => "conversation", "id" => Ecto.UUID.generate()},
          actor: user
        )

      {:ok, s2} =
        Magus.Workbench.open_workbench_tab(
          s1,
          %{"type" => "conversation", "id" => Ecto.UUID.generate()},
          actor: user
        )

      %{user: user, session: s2}
    end

    test "reorders tabs by id list", %{user: user, session: session} do
      [a, b] = session.tabs

      {:ok, updated} =
        Magus.Workbench.reorder_workbench_tabs(session, [b["id"], a["id"]], actor: user)

      assert Enum.at(updated.tabs, 0)["id"] == b["id"]
      assert Enum.at(updated.tabs, 1)["id"] == a["id"]
    end

    test "rejects a list that does not contain exactly the current tab ids",
         %{user: user, session: session} do
      assert {:error, _} =
               Magus.Workbench.reorder_workbench_tabs(session, ["tab_bogus"], actor: user)
    end
  end
end
