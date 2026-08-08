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

    test "deletes user with an owned skill" do
      user = generate(user())

      {:ok, _skill} =
        Magus.Skills.Skill
        |> Ash.Changeset.for_create(
          :create,
          %{name: "probe-skill", description: "d", body: "b"},
          actor: user,
          authorize?: false
        )
        |> Ash.create()

      assert :ok = AccountDeletion.execute(user)

      assert Magus.Skills.Skill
             |> Ash.Query.filter(user_id == ^user.id)
             |> Ash.count!(authorize?: false) == 0
    end

    test "deletes user with a memory profile" do
      user = generate(user())

      {:ok, _profile} =
        Magus.Memory.UserProfile
        |> Ash.Changeset.for_create(
          :create,
          %{user_id: user.id, document: "profile text"},
          authorize?: false
        )
        |> Ash.create()

      assert :ok = AccountDeletion.execute(user)

      assert Magus.Memory.UserProfile
             |> Ash.Query.filter(user_id == ^user.id)
             |> Ash.count!(authorize?: false) == 0
    end

    test "deletes user with brain page paper-trail versions" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))

      # A page body write stamps a brain_pages_versions row with the actor.
      _page = brain_page(brain_id: brain.id, user_id: user.id, content: "some text")

      assert :ok = AccountDeletion.execute(user)
    end

    test "deletes user who is a member of someone else's organization" do
      owner = generate(user())
      member = generate(user())

      {:ok, org} =
        Magus.Organizations.Organization
        |> Ash.Changeset.for_create(
          :create,
          %{name: "Acme", slug: "acme-#{System.unique_integer([:positive])}"},
          actor: owner,
          authorize?: false
        )
        |> Ash.create()

      {:ok, _member_row} =
        Magus.Organizations.OrganizationMember
        |> Ash.Changeset.for_create(
          :create_member,
          %{
            organization_id: org.id,
            user_id: member.id,
            invite_email: to_string(member.email)
          },
          authorize?: false
        )
        |> Ash.create()

      assert :ok = AccountDeletion.execute(member)
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

  describe "FK coverage" do
    # Every ON DELETE NO ACTION foreign key into `users` must be cleared by
    # AccountDeletion before it deletes the User row, or the delete blows up
    # with an Ecto.ConstraintError and the account survives. New tables are
    # easy to add and impossible to notice, so assert the full set here: if
    # this fails, handle the new column in AccountDeletion (destroy the owned
    # rows, list it in @auxiliary_user_tables, or nullify it in
    # @paper_trail_tables) and then add it below.
    @handled [
      # cleaned up as owned content, or via @auxiliary_user_tables
      {"agent_activity_logs", "user_id"},
      {"agent_inbox_events", "user_id"},
      {"conversations", "user_id"},
      {"conversation_share_links", "created_by_id"},
      {"curation_inbox_items", "user_id"},
      {"curation_interest_profiles", "user_id"},
      {"curation_sources", "user_id"},
      {"custom_agents", "user_id"},
      {"drafts", "user_id"},
      {"feature_usage_events", "user_id"},
      {"files", "user_id"},
      {"ingestion_entries", "user_id"},
      {"integration_audit_logs", "user_id"},
      {"integration_input_messages", "user_id"},
      {"integration_output_messages", "user_id"},
      {"knowledge_sources", "user_id"},
      {"messages", "created_by_id"},
      {"notifications", "user_id"},
      {"organization_members", "user_id"},
      {"pane_states", "user_id"},
      {"plan_task_pane_states", "user_id"},
      {"prompts", "user_id"},
      {"resource_accesses", "granted_by_id"},
      {"sessions", "created_by_id"},
      {"skills", "user_id"},
      {"super_brain_episodes", "source_user_id"},
      {"user_integrations", "user_id"},
      {"user_profiles", "user_id"},
      {"user_subscriptions", "user_id"},
      {"user_usage_overrides", "user_id"},
      {"workspace_members", "user_id"},
      # nullified via @paper_trail_tables
      {"brain_blocks_versions", "user_id"},
      {"brain_pages_versions", "user_id"},
      {"drafts_versions", "user_id"},
      {"organization_members_versions", "user_id"},
      {"organizations_versions", "owner_id"},
      {"prompts_versions", "user_id"},
      {"user_subscriptions_versions", "user_id"},
      {"workspace_members_versions", "user_id"},
      {"workspaces_versions", "user_id"}
    ]

    # Owning an organization still blocks deletion with a raw FK error. Whether
    # that should transfer, archive, or refuse in preflight is an open product
    # decision, tracked rather than silently cascaded: an org carries other
    # members, billing (user_subscriptions.sponsor_org_id) and workspaces.
    @known_unhandled [{"organizations", "owner_id"}]

    test "AccountDeletion covers every NO ACTION foreign key into users" do
      %{rows: rows} =
        Magus.Repo.query!("""
        SELECT c.conrelid::regclass::text, a.attname
        FROM pg_constraint c
        JOIN unnest(c.conkey) WITH ORDINALITY AS k(attnum, ord) ON true
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.attnum
        WHERE c.contype = 'f'
          AND c.confrelid = 'users'::regclass
          AND c.confdeltype = 'a'
        """)

      actual = rows |> Enum.map(fn [table, column] -> {table, column} end) |> MapSet.new()
      accounted_for = MapSet.new(@handled ++ @known_unhandled)

      assert MapSet.difference(actual, accounted_for) |> MapSet.to_list() == [],
             "new NO ACTION FK into users — handle it in AccountDeletion, then list it here"

      assert MapSet.difference(accounted_for, actual) |> MapSet.to_list() == [],
             "listed FK no longer exists — drop it from this test (and from AccountDeletion)"
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
