defmodule Magus.Accounts.AccountDeletionTest do
  use Magus.ResourceCase, async: false

  import Magus.Generators

  require Ash.Query

  alias Magus.Accounts.AccountDeletion

  describe "preflight/1" do
    test "returns counts for a normal user with no workspaces" do
      user = generate(user())

      assert {:ok, summary} = AccountDeletion.preflight(user)

      assert summary.active_subscription == nil
      assert summary.multiplayer_membership_count == 0
      assert summary.conversation_count == 0
      assert summary.brain_count == 0
      assert summary.memory_count == 0
      assert summary.prompt_count == 0
      assert summary.draft_count == 0
      assert summary.custom_agent_count == 0
    end

    test "counts the user's own resources" do
      user = generate(user())
      {:ok, _conv} = Magus.Chat.create_conversation(%{title: "C"}, actor: user)

      assert {:ok, summary} = AccountDeletion.preflight(user)
      assert summary.conversation_count == 1
    end

    test "blocks when user is the only admin of a workspace" do
      user = generate(user())
      ensure_workspace_plan(user)
      ws = generate(workspace(actor: user))

      assert {:error, :sole_admin_workspaces, [%{id: ws_id}]} =
               AccountDeletion.preflight(user)

      assert ws_id == ws.id
    end

    test "passes when a workspace has another admin" do
      owner = generate(user())
      other_admin = generate(user())
      ensure_workspace_plan(owner)
      ws = generate(workspace(actor: owner))

      Magus.Workspaces.WorkspaceMember
      |> Ash.Changeset.for_create(
        :create_admin,
        %{
          user_id: other_admin.id,
          workspace_id: ws.id,
          invite_email: to_string(other_admin.email)
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

      assert {:ok, _summary} = AccountDeletion.preflight(owner)
    end

    test "returns active_subscription details when the user has one" do
      user = generate(user())

      plan = generate(usage_plan())

      period_end = DateTime.add(DateTime.utc_now(), 86_400, :second)

      {:ok, _sub} =
        Magus.Usage.Account
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: user.id,
            usage_plan_id: plan.id,
            status: :active,
            current_period_end: period_end,
            storage_usage_bytes: 0
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      assert {:ok, summary} = AccountDeletion.preflight(user)
      assert summary.active_subscription.plan == plan.key
      assert summary.active_subscription.current_period_end != nil
    end
  end

  describe "execute/1 - content delete" do
    test "deletes user-owned conversations, memories, brains, prompts, drafts" do
      user = generate(user())
      {:ok, conv} = Magus.Chat.create_conversation(%{title: "C"}, actor: user)

      {:ok, _msg} =
        Magus.Chat.create_message(%{conversation_id: conv.id, text: "hi"}, actor: user)

      {:ok, _mem} =
        Magus.Memory.create_memory(conv.id, user.id, "n", %{summary: "s"}, actor: user)

      {:ok, _brain} = Magus.Brain.create_brain(%{title: "B"}, actor: user)

      {:ok, _prompt} =
        Magus.Library.create_prompt(%{name: "P", content: "x", type: :user}, actor: user)

      {:ok, _draft} = Magus.Drafts.create_draft(conv.id, "D", "content", user.id, actor: user)

      assert :ok = AccountDeletion.execute(user)

      require Ash.Query

      assert Magus.Chat.Conversation
             |> Ash.Query.filter(user_id == ^user.id)
             |> Ash.count!(authorize?: false) == 0

      assert Magus.Memory.Memory
             |> Ash.Query.filter(user_id == ^user.id)
             |> Ash.count!(authorize?: false) == 0

      assert Magus.Brain.BrainResource
             |> Ash.Query.filter(user_id == ^user.id)
             |> Ash.count!(authorize?: false) == 0

      assert Magus.Library.Prompt
             |> Ash.Query.filter(user_id == ^user.id)
             |> Ash.count!(authorize?: false) == 0

      assert Magus.Drafts.Draft
             |> Ash.Query.filter(user_id == ^user.id)
             |> Ash.count!(authorize?: false) == 0
    end

    test "hard-deletes the User row" do
      user = generate(user())
      assert :ok = AccountDeletion.execute(user)

      require Ash.Query

      assert Magus.Accounts.User
             |> Ash.Query.filter(id == ^user.id)
             |> Ash.read_one(authorize?: false) == {:ok, nil}
    end

    test "re-checks sole-admin status and aborts cleanly when stale" do
      user = generate(user())
      ensure_workspace_plan(user)
      _ws = generate(workspace(actor: user))

      assert {:error, :sole_admin_workspaces, _} = AccountDeletion.execute(user)

      require Ash.Query
      # User must still exist after the abort
      assert {:ok, %{}} =
               Magus.Accounts.User
               |> Ash.Query.filter(id == ^user.id)
               |> Ash.read_one(authorize?: false)
    end

    test "deletes user with conversation-in-folder (FK ordering for folders)" do
      user = generate(user())
      {:ok, folder} = Magus.Chat.create_folder(%{name: "Work"}, actor: user)

      {:ok, _conv} =
        Magus.Chat.create_conversation(%{title: "C", folder_id: folder.id}, actor: user)

      assert :ok = AccountDeletion.execute(user)
    end

    test "deletes user with custom_agent referenced by other tables" do
      user = generate(user())

      # Personal (no-workspace) custom agent — keeps the test focused on
      # the FK-ordering bug for custom_agents (not workspace policies).
      {:ok, agent} =
        Magus.Agents.create_custom_agent(
          %{name: "TestBot", instructions: "do stuff"},
          actor: user
        )

      # Memory referencing the agent (NO ACTION FK to custom_agents).
      {:ok, _mem} =
        Magus.Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "fact", summary: "x"},
          actor: user
        )

      assert :ok = AccountDeletion.execute(user)
    end

    test "preserves message_usage rows with NULL user_id" do
      user = generate(user())
      {:ok, conv} = Magus.Chat.create_conversation(%{title: "C"}, actor: user)

      # Create a usage row tied to the user but not to a message — message
      # creation triggers an async agent dispatch we want to keep out of the
      # test. The user_id NULLing path doesn't need a message anyway.
      {:ok, _usage} =
        Magus.Usage.MessageUsage
        |> Ash.Changeset.for_create(
          :create,
          %{
            conversation_id: conv.id,
            user_id: user.id,
            prompt_tokens: 10,
            completion_tokens: 5,
            model_name: "test-model"
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      assert :ok = AccountDeletion.execute(user)

      rows = Ash.read!(Magus.Usage.MessageUsage, authorize?: false)
      test_rows = Enum.filter(rows, fn r -> r.model_name == "test-model" end)

      assert length(test_rows) == 1
      assert hd(test_rows).user_id == nil
    end

    test "anonymizes the user's messages in OTHER users' conversations (instead of deleting)" do
      owner = generate(user())
      member = generate(user())

      {:ok, conv} = Magus.Chat.create_conversation(%{title: "Multi"}, actor: owner)

      # Promote the conversation to multiplayer (sets is_multiplayer=true and
      # adds the owner as an accepted member).
      conv
      |> Ash.Changeset.for_update(:enable_multiplayer, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

      Magus.Chat.ConversationMember
      |> Ash.Changeset.for_create(
        :add_member,
        %{conversation_id: conv.id, user_id: member.id, role: :member},
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

      Magus.Chat.ConversationMember
      |> Ash.Query.filter(conversation_id == ^conv.id and user_id == ^member.id)
      |> Ash.read_one!(authorize?: false)
      |> Ash.Changeset.for_update(:accept_invitation, %{}, authorize?: false)
      |> Ash.update!(authorize?: false)

      {:ok, member_msg} =
        Magus.Chat.create_message(
          %{conversation_id: conv.id, text: "from member"},
          actor: member
        )

      member_msg_id = member_msg.id

      assert :ok = AccountDeletion.execute(member)

      reloaded =
        Magus.Chat.Message
        |> Ash.Query.filter(id == ^member_msg_id)
        |> Ash.read_one(authorize?: false)

      assert {:ok, %{text: "from member", created_by_id: nil}} = reloaded
    end
  end

  describe "execute/1 - subscription handling" do
    # Stripe subscription-cancellation behaviour (the cloud `AccountLifecycle`
    # impl) lives in magus_cloud. The open-core edition uses the no-op lifecycle:
    # deletion proceeds regardless of any subscription, covered below.
    test "no-op when user has no active subscription" do
      user = generate(user())

      # No Stripe stub installed — if execute/1 calls the real client, the test will fail loudly.
      assert :ok = AccountDeletion.execute(user)
    end

    test "treats Stripe 'already canceled' response as success and proceeds with deletion" do
      user = generate(user())

      plan = generate(usage_plan())

      {:ok, _sub} =
        Magus.Usage.Account
        |> Ash.Changeset.for_create(
          :create,
          %{
            user_id: user.id,
            usage_plan_id: plan.id,
            status: :active,
            stripe_subscription_id: "sub_RETRY",
            storage_usage_bytes: 0
          },
          authorize?: false
        )
        |> Ash.create(authorize?: false)

      Application.put_env(
        :magus,
        :stripe_client,
        {:fun, fn :cancel_subscription, _sub_id, _opts -> {:error, :already_canceled} end}
      )

      on_exit(fn -> Application.delete_env(:magus, :stripe_client) end)

      assert :ok = AccountDeletion.execute(user)
    end
  end
end
