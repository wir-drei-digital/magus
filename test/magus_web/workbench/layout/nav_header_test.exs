defmodule MagusWeb.Workbench.Layout.NavHeaderTest do
  use MagusWeb.LiveViewCase, async: false
  import Magus.Generators

  alias MagusWeb.Workbench.Layout.NavHeader

  defp base_assigns(user, ws, mode) do
    %{
      id: "nav-header",
      current_user: user,
      current_mode: mode,
      current_workspace: ws,
      workspaces: [ws],
      nav_filter: :all,
      search_query: ""
    }
  end

  test "chat mode renders filter pills, search button, and new-chat button" do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    html = Phoenix.LiveViewTest.render_component(NavHeader, base_assigns(user, ws, :chat))

    assert html =~ ~s(data-nav-filter="all")
    assert html =~ ~s(data-nav-filter="shared")
    assert html =~ ~s(data-nav-filter="personal")
    assert html =~ ~s(data-new-chat)
    assert html =~ ~s(data-search-button)
    refute html =~ ~s(data-nav-search)
  end

  test "brain mode renders filter pills and search button but no new-chat button" do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    html = Phoenix.LiveViewTest.render_component(NavHeader, base_assigns(user, ws, :brain))

    assert html =~ ~s(data-nav-filter="all")
    assert html =~ ~s(data-search-button)
    refute html =~ ~s(data-nav-search)
    refute html =~ ~s(data-new-chat)
  end

  test "agents mode shows search button and filter pills, no new-chat" do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    html = Phoenix.LiveViewTest.render_component(NavHeader, base_assigns(user, ws, :agents))

    assert html =~ ~s(data-nav-filter="all")
    assert html =~ ~s(data-search-button)
    refute html =~ ~s(data-nav-search)
    refute html =~ ~s(data-new-chat)
  end

  test "prompts mode shows search button and filter pills, no new-chat" do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))

    html = Phoenix.LiveViewTest.render_component(NavHeader, base_assigns(user, ws, :prompts))

    assert html =~ ~s(data-nav-filter="all")
    assert html =~ ~s(data-search-button)
    refute html =~ ~s(data-nav-search)
    refute html =~ ~s(data-new-chat)
  end
end
