defmodule Magus.Notifications.NotificationTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  describe "create_notification" do
    test "creates a notification for user" do
      user = generate(user())

      {:ok, notification} =
        Magus.Notifications.create_notification(
          %{
            user_id: user.id,
            title: "Test Notification",
            body: "Something happened",
            notification_type: :task_update,
            target_conversation_id: Ash.UUIDv7.generate()
          },
          authorize?: false
        )

      assert notification.title == "Test Notification"
      assert notification.body == "Something happened"
      assert notification.notification_type == :task_update
      assert notification.user_id == user.id
      assert notification.read_at == nil
    end
  end

  describe "pub_sub :create payload" do
    # The SPA bell renders live-arriving notifications from this payload alone.
    # The skill-approval card needs metadata.approve_phrase; without it the
    # card silently degrades to a plain row (regression: metadata was dropped).
    test "transform carries metadata and inserted_at" do
      publication =
        Magus.Notifications.Notification
        |> Ash.Notifier.PubSub.Info.publications()
        |> Enum.find(&(&1.action == :create))

      payload =
        publication.transform.(%Ash.Notifier.Notification{
          resource: Magus.Notifications.Notification,
          data: %{
            id: Ash.UUIDv7.generate(),
            title: "Skill approval needed",
            body: "Allow?",
            notification_type: :approval_request,
            target_conversation_id: nil,
            user_id: Ash.UUIDv7.generate(),
            metadata: %{"approve_phrase" => "Approve skill: x"},
            inserted_at: DateTime.utc_now()
          }
        })

      assert payload.metadata == %{"approve_phrase" => "Approve skill: x"}
      assert %DateTime{} = payload.inserted_at
    end
  end

  describe "list_unread_notifications" do
    test "returns only unread notifications for the actor" do
      user = generate(user())
      other_user = generate(user())

      # Create 2 unread for user
      for i <- 1..2 do
        Magus.Notifications.create_notification(
          %{user_id: user.id, title: "Unread #{i}", notification_type: :system},
          authorize?: false
        )
      end

      # Create 1 for other user
      Magus.Notifications.create_notification(
        %{user_id: other_user.id, title: "Other", notification_type: :system},
        authorize?: false
      )

      {:ok, notifications} = Magus.Notifications.list_unread_notifications(actor: user)
      assert length(notifications) == 2
      assert Enum.all?(notifications, &(&1.user_id == user.id))
    end

    test "excludes read notifications" do
      user = generate(user())

      {:ok, notification} =
        Magus.Notifications.create_notification(
          %{user_id: user.id, title: "Will be read", notification_type: :system},
          authorize?: false
        )

      Magus.Notifications.mark_notification_read(notification, actor: user)

      {:ok, unread} = Magus.Notifications.list_unread_notifications(actor: user)
      assert unread == []
    end
  end

  describe "mark_notification_read" do
    test "sets read_at timestamp" do
      user = generate(user())

      {:ok, notification} =
        Magus.Notifications.create_notification(
          %{user_id: user.id, title: "Read me", notification_type: :system},
          authorize?: false
        )

      assert notification.read_at == nil

      {:ok, updated} = Magus.Notifications.mark_notification_read(notification, actor: user)
      assert updated.read_at != nil
    end
  end

  describe "unread_notification_count" do
    test "returns correct count" do
      user = generate(user())

      for i <- 1..3 do
        Magus.Notifications.create_notification(
          %{user_id: user.id, title: "N#{i}", notification_type: :system},
          authorize?: false
        )
      end

      {:ok, count} = Magus.Notifications.unread_notification_count(user.id)
      assert count == 3
    end

    test "returns 0 when all read" do
      user = generate(user())

      {:ok, n} =
        Magus.Notifications.create_notification(
          %{user_id: user.id, title: "N1", notification_type: :system},
          authorize?: false
        )

      Magus.Notifications.mark_notification_read(n, actor: user)

      {:ok, count} = Magus.Notifications.unread_notification_count(user.id)
      assert count == 0
    end
  end
end
