defmodule MagusWeb.Components.PresenceIndicatorTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  alias MagusWeb.Components.PresenceIndicator

  defp render_indicator(attrs) do
    render_component(&PresenceIndicator.presence_indicator/1, attrs)
  end

  describe ":avatars variant" do
    test "renders nothing when no other viewers" do
      html =
        render_indicator(%{
          viewers: [%{user_id: "me", name: "Me", avatar_path: nil, color: "#fff", visible?: true}],
          current_user_id: "me",
          variant: :avatars,
          topic: "presence:conversation:abc"
        })

      refute html =~ "role=\"group\""
    end

    test "renders one circle for one other viewer" do
      html =
        render_indicator(%{
          viewers: [
            %{user_id: "me", name: "Me", avatar_path: nil, color: "#fff", visible?: true},
            %{user_id: "u2", name: "Bob", avatar_path: nil, color: "#3b82f6", visible?: true}
          ],
          current_user_id: "me",
          variant: :avatars,
          topic: "presence:conversation:abc"
        })

      assert html =~ "role=\"group\""
      assert html =~ "Bob"
      assert html =~ "#3b82f6"
    end

    test "filters out hidden viewers" do
      html =
        render_indicator(%{
          viewers: [
            %{user_id: "u2", name: "Bob", avatar_path: nil, color: "#3b82f6", visible?: false}
          ],
          current_user_id: "me",
          variant: :avatars,
          topic: "presence:conversation:abc"
        })

      refute html =~ "Bob"
    end

    test "shows +N pill past max" do
      viewers =
        for i <- 1..8,
            do: %{
              user_id: "u#{i}",
              name: "User#{i}",
              avatar_path: nil,
              color: "#fff",
              visible?: true
            }

      html =
        render_indicator(%{
          viewers: viewers,
          current_user_id: "me",
          variant: :avatars,
          max: 5,
          topic: "presence:conversation:abc"
        })

      assert html =~ "+3"
    end
  end

  describe ":dots variant" do
    test "renders smaller circles and default max=3" do
      viewers =
        for i <- 1..5,
            do: %{
              user_id: "u#{i}",
              name: "U#{i}",
              avatar_path: nil,
              color: "#fff",
              visible?: true
            }

      html =
        render_indicator(%{
          viewers: viewers,
          current_user_id: "me",
          variant: :dots,
          topic: "presence:page:abc"
        })

      assert html =~ "+2"
      assert html =~ "w-6"
    end
  end
end
