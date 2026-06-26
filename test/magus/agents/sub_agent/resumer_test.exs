defmodule Magus.Agents.SubAgent.ResumerTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.SubAgent.Resumer

  setup do
    user = generate(user())
    conv = generate(conversation(actor: user))
    %{user: user, conv: conv}
  end

  defp insert_run(conv, attrs \\ []) do
    sub_agent_run(
      Keyword.merge(
        [
          source_conversation_id: conv.id,
          kind: :subtask,
          source: :sub_agent_spawn
        ],
        attrs
      )
    )
  end

  describe "gate: kind != :subtask" do
    test "returns :skipped_not_subtask for non-subtask runs", %{conv: conv} do
      run = insert_run(conv, kind: :consult, source: :mention)
      {:ok, started} = Magus.Agents.start_agent_run(run, authorize?: false)

      {:ok, completed} =
        Magus.Agents.complete_agent_run(started, %{result_text: "ok"}, authorize?: false)

      assert Resumer.maybe_resume_parent(completed) == :skipped_not_subtask
    end
  end

  describe "gate: other in-flight peers" do
    test "returns :skipped_other_in_flight when peer subtask still pending", %{conv: conv} do
      r1 = insert_run(conv)
      _peer = insert_run(conv)

      {:ok, started} = Magus.Agents.start_agent_run(r1, authorize?: false)

      {:ok, completed} =
        Magus.Agents.complete_agent_run(started, %{result_text: "ok"}, authorize?: false)

      assert Resumer.maybe_resume_parent(completed) == :skipped_other_in_flight
    end
  end

  describe "gate: no undelivered runs" do
    test "returns :skipped_no_undelivered when run is already delivered", %{conv: conv} do
      r1 = insert_run(conv)
      {:ok, started} = Magus.Agents.start_agent_run(r1, authorize?: false)

      {:ok, completed} =
        Magus.Agents.complete_agent_run(started, %{result_text: "ok"}, authorize?: false)

      {:ok, _delivered} =
        Magus.Agents.mark_delivered_agent_run(completed, authorize?: false)

      assert Resumer.maybe_resume_parent(completed) == :skipped_no_undelivered
    end
  end

  # Note: we cannot easily exercise :resumed and :skipped_busy in a unit
  # test without a running InstanceManager. Those are covered by E2E live tests
  # (Task 12).
end
