defmodule Magus.Workbench.UpdateTabPrimaryTest do
  use Magus.ResourceCase, async: true

  alias Magus.Workbench

  describe "update_tab_primary/3" do
    setup do
      user = generate(user())
      {:ok, session} = Workbench.get_or_create_tab_session(user.id, nil, actor: user)

      {:ok, session} =
        Workbench.open_workbench_tab(
          session,
          %{"type" => "file_browser", "scope" => "my_files", "id" => nil},
          %{label: "My Files"},
          actor: user
        )

      tab_id = session.active_tab_id
      %{user: user, session: session, tab_id: tab_id}
    end

    test "replaces matching tab's primary in place", %{
      user: user,
      session: session,
      tab_id: tab_id
    } do
      new_primary = %{"type" => "file_browser", "scope" => "recent", "id" => nil}

      {:ok, updated} =
        Workbench.update_tab_primary(session, tab_id, new_primary, actor: user)

      tab = Enum.find(updated.tabs, &(&1["id"] == tab_id))
      assert tab["primary"] == new_primary
      assert updated.active_tab_id == tab_id, "active_tab_id should not change"
    end

    test "preserves other tabs", %{user: user, session: session, tab_id: tab_id} do
      {:ok, session} =
        Workbench.open_workbench_tab(
          session,
          %{"type" => "file_browser", "scope" => "trash", "id" => nil},
          %{label: "Trash"},
          actor: user
        )

      {:ok, updated} =
        Workbench.update_tab_primary(
          session,
          tab_id,
          %{"type" => "file_browser", "scope" => "templates", "id" => nil},
          actor: user
        )

      assert length(updated.tabs) == 2
    end

    test "returns the session unchanged if tab_id is unknown", %{user: user, session: session} do
      {:ok, updated} =
        Workbench.update_tab_primary(
          session,
          "tab_does_not_exist",
          %{"type" => "file_browser", "scope" => "recent", "id" => nil},
          actor: user
        )

      assert updated.tabs == session.tabs
    end
  end
end
