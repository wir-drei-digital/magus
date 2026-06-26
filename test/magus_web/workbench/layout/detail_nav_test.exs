defmodule MagusWeb.Workbench.Layout.DetailNavTest do
  use MagusWeb.LiveViewCase, async: false

  import Phoenix.LiveViewTest

  alias MagusWeb.Workbench.Layout.DetailNav

  test "renders sections with active state" do
    detail_view = %{
      title: "Settings",
      sections: [
        %{key: :profile, label: "Profile", href: "/settings/profile", active?: true},
        %{key: :preferences, label: "Preferences", href: "/settings/preferences", active?: false}
      ]
    }

    html =
      render_component(DetailNav,
        id: "detail-nav",
        detail_view: detail_view,
        current_user: %{id: "u1"}
      )

    assert html =~ "Profile"
    assert html =~ ~s(data-detail-section="profile")
    assert html =~ ~s(data-detail-section="preferences")
    assert html =~ "bg-wb-surface-2"
  end

  test "renders empty section list when sections is missing" do
    html =
      render_component(DetailNav,
        id: "detail-nav",
        detail_view: %{title: "Empty"},
        current_user: %{id: "u1"}
      )

    assert html =~ "Empty"
    refute html =~ ~s(data-detail-section)
  end
end
