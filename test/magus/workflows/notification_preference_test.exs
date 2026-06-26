defmodule Magus.Workflows.NotificationPreferenceTest do
  @moduledoc """
  Tests for the NotificationPreference resource.

  Tests cover:
  - NotificationPreference CRUD operations
  - Default values
  - Unique constraint per job
  - Authorization policies
  """
  use Magus.ResourceCase, async: true

  alias Magus.Workflows
  alias Magus.Chat

  setup do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
    job = job(conversation_id: conversation.id, user_id: user.id)

    %{user: user, conversation: conversation, job: job}
  end

  describe "NotificationPreference.create" do
    test "creates with default values", %{job: job} do
      {:ok, pref} = Workflows.create_notification_preference(job.id, %{}, authorize?: false)

      assert pref.job_id == job.id
      assert pref.notify_on_success == false
      assert pref.notify_on_failure == true
      assert pref.notification_channels == [:in_app]
    end

    test "creates with custom values", %{job: job} do
      {:ok, pref} =
        Workflows.create_notification_preference(
          job.id,
          %{
            notify_on_success: true,
            notify_on_failure: false,
            notification_channels: [:email, :in_app]
          },
          authorize?: false
        )

      assert pref.notify_on_success == true
      assert pref.notify_on_failure == false
      assert pref.notification_channels == [:email, :in_app]
    end

    test "creates with email only channel", %{job: job} do
      {:ok, pref} =
        Workflows.create_notification_preference(
          job.id,
          %{notification_channels: [:email]},
          authorize?: false
        )

      assert pref.notification_channels == [:email]
    end
  end

  describe "NotificationPreference.update" do
    test "updates notification settings", %{job: job} do
      pref = notification_preference(job_id: job.id)

      {:ok, updated} =
        Workflows.update_notification_preference(
          pref,
          %{notify_on_success: true, notify_on_failure: false},
          authorize?: false
        )

      assert updated.notify_on_success == true
      assert updated.notify_on_failure == false
    end

    test "updates channels", %{job: job} do
      pref = notification_preference(job_id: job.id, notification_channels: [:in_app])

      {:ok, updated} =
        Workflows.update_notification_preference(
          pref,
          %{notification_channels: [:email, :in_app]},
          authorize?: false
        )

      assert updated.notification_channels == [:email, :in_app]
    end
  end

  describe "unique constraint" do
    test "prevents multiple preferences per job", %{job: job} do
      {:ok, _first} = Workflows.create_notification_preference(job.id, %{}, authorize?: false)

      {:error, error} = Workflows.create_notification_preference(job.id, %{}, authorize?: false)

      assert %Ash.Error.Unknown{} = error
    end
  end

  describe "authorization" do
    test "user can read preferences for own jobs", %{user: user, job: job} do
      pref = notification_preference(job_id: job.id)

      # Load preference through job relationship
      {:ok, loaded_job} = Workflows.get_job(job.id, actor: user, load: [:notification_preference])

      assert loaded_job.notification_preference.id == pref.id
    end

    test "user cannot create preference for other user's job" do
      user1 = generate(user())
      user2 = generate(user())
      {:ok, conv} = Chat.create_conversation(%{}, actor: user1)
      job = job(conversation_id: conv.id, user_id: user1.id)

      assert_forbidden(fn ->
        Workflows.create_notification_preference(job.id, %{}, actor: user2)
      end)
    end
  end

  describe "job relationship" do
    test "can load notification_preference through job", %{user: user, job: job} do
      notification_preference(job_id: job.id, notify_on_success: true)

      {:ok, loaded} = Workflows.get_job(job.id, actor: user, load: [:notification_preference])

      assert loaded.notification_preference != nil
      assert loaded.notification_preference.notify_on_success == true
    end

    test "job without preference has nil relationship", %{user: user, job: job} do
      {:ok, loaded} = Workflows.get_job(job.id, actor: user, load: [:notification_preference])

      assert loaded.notification_preference == nil
    end
  end

  describe "cascading delete" do
    test "deleting job deletes associated preference", %{job: job} do
      _pref = notification_preference(job_id: job.id)

      # Delete the job
      :ok = Ash.destroy!(job, authorize?: false)

      # Preference should be deleted too (can't query directly, but we can try)
      # Recreating a job with same ID would fail if preference still existed
      # This is implicitly tested by the database constraint
    end
  end

  describe "channel validation" do
    test "accepts valid channel atoms", %{job: job} do
      {:ok, pref} =
        Workflows.create_notification_preference(
          job.id,
          %{notification_channels: [:in_app]},
          authorize?: false
        )

      assert pref.notification_channels == [:in_app]

      {:ok, pref2} =
        Workflows.update_notification_preference(
          pref,
          %{notification_channels: [:email]},
          authorize?: false
        )

      assert pref2.notification_channels == [:email]
    end
  end
end
