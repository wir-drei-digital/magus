defmodule Magus.PresenceTest do
  use ExUnit.Case, async: true

  alias Phoenix.LiveView.Socket

  defp connected_socket(user) do
    %Socket{
      assigns: %{__changed__: %{}, current_user: user, __presences__: %{}, viewers: %{}},
      transport_pid: self()
    }
  end

  defp unconnected_socket(user) do
    %Socket{
      assigns: %{__changed__: %{}, current_user: user, __presences__: %{}, viewers: %{}},
      transport_pid: nil
    }
  end

  defp user(overrides \\ %{}) do
    Map.merge(
      %{id: Ecto.UUID.generate(), name: "Alice", email: "a@example.com", avatar_path: nil},
      overrides
    )
  end

  test "track/3 is a no-op when socket is not connected" do
    socket = unconnected_socket(user())
    new_socket = Magus.Presence.track(socket, :conversation, Ecto.UUID.generate())
    assert new_socket.assigns.__presences__ == %{}
  end

  test "track/3 is a no-op when there is no current_user" do
    socket = %Socket{
      assigns: %{__changed__: %{}, __presences__: %{}, viewers: %{}},
      transport_pid: self()
    }

    conv_id = Ecto.UUID.generate()
    new_socket = Magus.Presence.track(socket, :conversation, conv_id)
    assert new_socket.assigns.__presences__ == %{}
  end

  test "track/3 records the topic and tracks the user under the topic" do
    user = user()
    socket = connected_socket(user)
    conv_id = Ecto.UUID.generate()

    new_socket = Magus.Presence.track(socket, :conversation, conv_id)
    topic = "presence:conversation:#{conv_id}"
    assert new_socket.assigns.__presences__[topic] == :tracked

    list = Magus.Presence.list(:conversation, conv_id)
    assert [%{user_id: uid, name: "Alice"}] = list
    assert uid == user.id
  end

  test "list/2 dedupes by user when the same user is tracked from two processes" do
    user = user()
    socket1 = connected_socket(user)
    conv_id = Ecto.UUID.generate()

    Magus.Presence.track(socket1, :conversation, conv_id)

    task =
      Task.async(fn ->
        socket2 = %Socket{
          assigns: %{__changed__: %{}, current_user: user, __presences__: %{}, viewers: %{}},
          transport_pid: self()
        }

        Magus.Presence.track(socket2, :conversation, conv_id)
        Process.sleep(100)
      end)

    Process.sleep(20)
    list = Magus.Presence.list(:conversation, conv_id)
    assert length(list) == 1

    Task.await(task)
  end

  test "handle_diff/2 updates viewers list for the matching topic" do
    user = user()
    socket = connected_socket(user)
    conv_id = Ecto.UUID.generate()

    socket = Magus.Presence.track(socket, :conversation, conv_id)
    topic = "presence:conversation:#{conv_id}"

    diff = %Phoenix.Socket.Broadcast{
      topic: topic,
      event: "presence_diff",
      payload: %{joins: %{}, leaves: %{}}
    }

    new_socket = Magus.Presence.handle_diff(socket, diff)

    # Even with an empty diff, the viewers list should be refreshed from
    # Phoenix.Presence.list, keyed by topic.
    assert Map.has_key?(new_socket.assigns.viewers, topic)
  end

  test "handle_diff/2 ignores broadcasts for untracked topics" do
    socket = connected_socket(user())

    diff = %Phoenix.Socket.Broadcast{
      topic: "presence:conversation:other",
      event: "presence_diff",
      payload: %{joins: %{}, leaves: %{}}
    }

    new_socket = Magus.Presence.handle_diff(socket, diff)
    refute Map.has_key?(new_socket.assigns.viewers, "presence:conversation:other")
  end

  test "handle_visibility/3 flips visible? meta on hidden, restores on visible" do
    user = user()
    socket = connected_socket(user)
    conv_id = Ecto.UUID.generate()
    socket = Magus.Presence.track(socket, :conversation, conv_id)
    topic = "presence:conversation:#{conv_id}"

    Magus.Presence.handle_visibility(socket, "presence:hidden", %{"topic" => topic})
    # Allow Presence to process the update.
    Process.sleep(50)

    [viewer] = Magus.Presence.list(:conversation, conv_id)
    refute viewer.visible?

    Magus.Presence.handle_visibility(socket, "presence:visible", %{"topic" => topic})
    Process.sleep(50)

    [viewer] = Magus.Presence.list(:conversation, conv_id)
    assert viewer.visible?
  end

  test "handle_visibility/3 is a no-op for untracked topics" do
    socket = connected_socket(user())

    result =
      Magus.Presence.handle_visibility(socket, "presence:hidden", %{
        "topic" => "presence:conversation:nope"
      })

    assert result == socket
  end
end
