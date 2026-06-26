defmodule Magus.Agents.Context.JobsContextTest do
  use Magus.DataCase, async: true

  alias Magus.Agents.Context.JobsContext
  alias Magus.Chat

  import Magus.Generators

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp create_context do
    user = generate(user())
    {:ok, conversation} = Chat.create_conversation(%{title: "Test"}, actor: user)
    %{user: user, conversation: conversation}
  end

  # ---------------------------------------------------------------------------
  # Tests for build/1 — nil cases
  # ---------------------------------------------------------------------------

  describe "build/1 returns nil" do
    test "for non-existent conversation (no jobs)" do
      assert JobsContext.build(Ecto.UUID.generate()) == nil
    end

    test "for conversation with no jobs" do
      %{conversation: conv} = create_context()
      assert JobsContext.build(conv.id) == nil
    end

    test "for non-binary input" do
      assert JobsContext.build(nil) == nil
      assert JobsContext.build(123) == nil
      assert JobsContext.build(:atom) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # Tests for build/1 — context string formatting
  # ---------------------------------------------------------------------------

  describe "build/1 with active jobs" do
    setup do
      create_context()
    end

    test "returns context string for a one-time job", %{user: user, conversation: conv} do
      job(
        conversation_id: conv.id,
        user_id: user.id,
        name: "Send Report",
        schedule_type: :one_time
      )

      result = JobsContext.build(conv.id, actor: user)

      assert is_binary(result)
      assert result =~ "## Active Jobs"
      assert result =~ "Send Report"
      assert result =~ "Do not create duplicate jobs"
    end

    test "returns context string for a cron job", %{user: user, conversation: conv} do
      job(
        conversation_id: conv.id,
        user_id: user.id,
        name: "Daily Digest",
        schedule_type: :cron,
        cron_expression: "0 9 * * *"
      )

      result = JobsContext.build(conv.id, actor: user)

      assert result =~ "Daily Digest"
      assert result =~ "0 9 * * *"
    end

    test "shows multiple jobs", %{user: user, conversation: conv} do
      job(conversation_id: conv.id, user_id: user.id, name: "Job Alpha")
      job(conversation_id: conv.id, user_id: user.id, name: "Job Beta")

      result = JobsContext.build(conv.id, actor: user)

      assert result =~ "Job Alpha"
      assert result =~ "Job Beta"
    end

    test "marks paused jobs", %{user: user, conversation: conv} do
      j = job(conversation_id: conv.id, user_id: user.id, name: "Paused Task")
      Magus.Workflows.pause_job(j, actor: user, authorize?: false)

      result = JobsContext.build(conv.id, actor: user)

      assert result =~ "[PAUSED]"
      assert result =~ "Paused Task"
    end

    test "excludes stopped jobs", %{user: user, conversation: conv} do
      j = job(conversation_id: conv.id, user_id: user.id, name: "Stopped Task")
      Magus.Workflows.stop_job(j, actor: user, authorize?: false)

      result = JobsContext.build(conv.id, actor: user)

      assert result == nil
    end

    test "includes timezone in cron schedule", %{user: user, conversation: conv} do
      job(
        conversation_id: conv.id,
        user_id: user.id,
        name: "Timed Job",
        schedule_type: :cron,
        cron_expression: "30 14 * * 1-5"
      )

      result = JobsContext.build(conv.id, actor: user)

      assert result =~ "30 14 * * 1-5"
      assert result =~ "UTC"
    end
  end
end
