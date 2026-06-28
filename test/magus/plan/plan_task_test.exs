defmodule Magus.Plan.PlanTaskTest do
  use Magus.ResourceCase, async: true

  alias Magus.Plan

  defp ctx do
    user = generate(user())
    brain = generate(brain(user_id: user.id))
    page = brain_page(brain_id: brain.id, user_id: user.id)
    %{user: user, brain: brain, page: page}
  end

  test "creates a task that belongs to a plan page" do
    %{user: user, page: page} = ctx()

    {:ok, task} = Plan.create_plan_task(page.id, %{title: "Research competitors"}, actor: user)

    assert task.brain_page_id == page.id
    assert is_nil(task.conversation_id)
    assert task.status == :open
  end

  test "plan tasks default to unassigned" do
    %{user: user, page: page} = ctx()
    {:ok, task} = Plan.create_plan_task(page.id, %{title: "Draft"}, actor: user)
    assert is_nil(task.assigned_to_agent)
    assert is_nil(task.assigned_to_user_id)
  end

  test "conversation tasks are unchanged (still default to the assistant)" do
    user = generate(user())
    {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)
    {:ok, task} = Plan.create_task(conversation.id, %{title: "Old style"}, actor: user)
    assert task.assigned_to_agent == "assistant"
    assert is_nil(task.brain_page_id)
  end

  test "priority defaults to :normal and accepts known values" do
    %{user: user, page: page} = ctx()

    {:ok, default} = Plan.create_plan_task(page.id, %{title: "A"}, actor: user)
    assert default.priority == :normal

    {:ok, urgent} = Plan.create_plan_task(page.id, %{title: "B", priority: :urgent}, actor: user)
    assert urgent.priority == :urgent
  end

  test "rejects an unknown priority" do
    %{user: user, page: page} = ctx()
    {:error, _} = Plan.create_plan_task(page.id, %{title: "C", priority: :whenever}, actor: user)
  end

  test "claimed_at is nil until claimed" do
    %{user: user, page: page} = ctx()
    {:ok, task} = Plan.create_plan_task(page.id, %{title: "D"}, actor: user)
    assert is_nil(task.claimed_at)
  end

  test "auto position is scoped per plan page" do
    %{user: user, brain: brain, page: page1} = ctx()
    page2 = brain_page(brain_id: brain.id, user_id: user.id)

    {:ok, a1} = Plan.create_plan_task(page1.id, %{title: "p1-1"}, actor: user)
    {:ok, a2} = Plan.create_plan_task(page1.id, %{title: "p1-2"}, actor: user)
    {:ok, b1} = Plan.create_plan_task(page2.id, %{title: "p2-1"}, actor: user)

    assert a1.position == 1
    assert a2.position == 2
    assert b1.position == 1
  end

  test "a user without access to the plan page cannot create a plan task on it" do
    # `page` is owned by ctx().user; `stranger` is an unrelated user.
    %{page: page} = ctx()
    stranger = generate(user())

    # `ActorCanAccessTaskPage` (min_role: :editor) must reject non-editors.
    assert_forbidden(fn ->
      Plan.create_plan_task(page.id, %{title: "x"}, actor: stranger)
    end)
  end

  test "rejects a task that belongs to both a conversation and a plan page" do
    %{user: user, page: page} = ctx()
    {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

    # Force BOTH containers: the `:create_plan` argument sets brain_page_id, then
    # we force conversation_id directly to trip the ValidateContainer guard.
    changeset =
      Magus.Plan.Task
      |> Ash.Changeset.for_create(:create_plan, %{title: "x", brain_page_id: page.id},
        actor: user
      )
      |> Ash.Changeset.force_change_attribute(:conversation_id, conversation.id)

    assert {:error, error} = Ash.create(changeset)
    assert_field_error(error, :brain_page_id, "cannot belong to both")
  end

  test "tasks_for_plan returns a page's tasks ordered by position" do
    %{user: user, page: page} = ctx()
    {:ok, _} = Plan.create_plan_task(page.id, %{title: "First"}, actor: user)
    {:ok, _} = Plan.create_plan_task(page.id, %{title: "Second"}, actor: user)

    {:ok, tasks} = Plan.tasks_for_plan(page.id, actor: user)
    assert Enum.map(tasks, & &1.title) == ["First", "Second"]
  end

  test "a user without access to the brain cannot read its plan tasks" do
    %{page: page} = ctx()
    stranger = generate(user())

    assert {:error, _} = Plan.tasks_for_plan(page.id, actor: stranger)
  end

  test "completing a recurring plan task does not crash or spawn a conversation task" do
    %{user: user, page: page} = ctx()
    {:ok, task} = Plan.create_plan_task(page.id, %{title: "Recurring plan task"}, actor: user)

    # Give the plan task a recurrence + future due date. SpawnRecurrence must
    # NO-OP for plan tasks (no conversation_id) instead of calling
    # create_task(nil, ...) and rolling back the completion.
    future = DateTime.add(DateTime.utc_now(), 7, :day)

    {:ok, task} =
      Plan.update_task(
        task,
        %{recurrence: %{frequency: :daily, interval: 1}, due_at: future},
        actor: user
      )

    # Completing must succeed (no crash / rollback from SpawnRecurrence).
    assert {:ok, done} = Plan.update_task(task, %{status: :done}, actor: user)
    assert done.status == :done
    # The completed task stays a plan task: no conversation_id was set, and no
    # recurrence spawned a conversation copy.
    assert is_nil(done.conversation_id)

    # No recurrence was spawned: THIS plan still has exactly its one task. Scope
    # the assertion to this plan (not a global table scan) so it is not sensitive
    # to orphan/concurrent rows on the shared test DB.
    {:ok, plan_tasks} = Plan.tasks_for_plan(page.id, actor: user)
    assert [done.id] == Enum.map(plan_tasks, & &1.id)
    assert Enum.all?(plan_tasks, &is_nil(&1.conversation_id))
  end

  test "creating a plan task broadcasts on the plan and brain topics" do
    %{user: user, brain: brain, page: page} = ctx()

    Phoenix.PubSub.subscribe(Magus.PubSub, "tasks:plan:#{page.id}")
    Phoenix.PubSub.subscribe(Magus.PubSub, "tasks:brain:#{brain.id}")

    {:ok, task} = Plan.create_plan_task(page.id, %{title: "Broadcasted"}, actor: user)

    assert_receive %Phoenix.Socket.Broadcast{
      topic: "tasks:plan:" <> _,
      event: "task.created",
      payload: %{task: %{id: id}}
    }

    assert id == task.id

    assert_receive %Phoenix.Socket.Broadcast{topic: "tasks:brain:" <> _, event: "task.created"}
  end

  test "get_task returns a plan task to a brain member" do
    %{user: user, page: page} = ctx()
    {:ok, task} = Plan.create_plan_task(page.id, %{title: "Findable"}, actor: user)

    {:ok, fetched} = Plan.get_task(task.id, actor: user)
    assert fetched.id == task.id
  end

  test "get_task does not return a plan task to a stranger" do
    %{page: page, user: user} = ctx()
    {:ok, task} = Plan.create_plan_task(page.id, %{title: "Hidden"}, actor: user)
    stranger = generate(user())

    assert {:error, _} = Plan.get_task(task.id, actor: stranger)
  end
end
