defmodule Magus.Accounts.UnconfirmedRetentionTest do
  @moduledoc """
  Task 5 (signup-abuse-hardening): the unconfirmed-account reaper deletes
  password signups that never confirmed their email past the configured
  TTL, skips users who own structure (organization, sole-admin workspace)
  or content (files, brain resources, or a conversation containing at
  least one complete agent reply — everything
  `AccountDeletion.cleanup_external_resources/1` destroys before its
  transaction opens, and therefore NOT protected by a transaction
  rollback), and is race-safe against a confirm racing the delete via two
  layers: `AccountDeletion.execute/2`'s fresh pre-cleanup `confirmed_at`
  check, and the conditional final-row DELETE inside its transaction (see
  `Magus.Accounts.AccountDeletion.PreconditionFailed`). A conversation
  holding only the user's own message (e.g. the confirmation gate's own
  blocked first turn) does NOT count as owned content — see
  `owns_conversations?/1` in `Magus.Accounts.UnconfirmedRetention`.
  """
  use Magus.DataCase, async: false

  require Ash.Query

  import Magus.Generators

  alias Magus.Accounts.AccountDeletion
  alias Magus.Accounts.UnconfirmedRetention
  alias Magus.Accounts.User
  alias Magus.Repo

  setup do
    original = Application.get_env(:magus, :unconfirmed_account_ttl_days)
    on_exit(fn -> Application.put_env(:magus, :unconfirmed_account_ttl_days, original) end)
    Application.put_env(:magus, :unconfirmed_account_ttl_days, 7)
    :ok
  end

  defp age!(user, days) do
    # push inserted_at into the past via Repo.update_all (no Ash action touches it)
    cutoff = DateTime.add(DateTime.utc_now(), -days * 86_400, :second)

    Repo.update_all(
      from(u in "users", where: u.id == type(^user.id, :binary_id)),
      set: [inserted_at: cutoff]
    )

    user
  end

  defp confirm!(user) do
    Repo.update_all(
      from(u in "users", where: u.id == type(^user.id, :binary_id)),
      set: [confirmed_at: DateTime.utc_now()]
    )

    user
  end

  defp user_exists?(user_id) do
    Repo.exists?(from(u in "users", where: u.id == type(^user_id, :binary_id)))
  end

  # A complete agent reply (role :agent, status :complete — the schema
  # default for :status, untouched by :upsert_response). This is the
  # refinement `owns_conversations?/1` gates on: without one, a conversation
  # holds only the user's own (possibly gate-blocked) message and does not
  # count as owned content. Runs authorize?: false and skips response_to_id
  # (nullable) since these tests don't need a real user message to respond to.
  defp add_complete_agent_message!(conversation_id) do
    Magus.Chat.Message
    |> Ash.Changeset.for_create(
      :upsert_response,
      %{
        id: Ash.UUIDv7.generate(),
        text: "agent reply",
        conversation_id: conversation_id,
        complete: true
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_organization!(owner) do
    ensure_workspace_plan(owner)
    unique = System.unique_integer([:positive, :monotonic])

    {:ok, org} =
      Magus.Organizations.create_organization(
        %{name: "Org #{unique}", slug: "org-#{unique}"},
        actor: owner
      )

    org
  end

  test "past-TTL unconfirmed user with no structure is deleted" do
    user = unconfirmed_user_fixture() |> age!(8)
    assert :deleted == UnconfirmedRetention.reap(user)
    refute user_exists?(user.id)
  end

  test "recent unconfirmed user survives" do
    user = unconfirmed_user_fixture() |> age!(2)
    assert :noop == UnconfirmedRetention.reap(user)
    assert user_exists?(user.id)
  end

  test "confirmed user survives regardless of age" do
    user = confirmed_user_fixture() |> age!(30)
    assert :noop == UnconfirmedRetention.reap(user)
    assert user_exists?(user.id)
  end

  test "nil TTL disables reaping" do
    Application.put_env(:magus, :unconfirmed_account_ttl_days, nil)
    user = unconfirmed_user_fixture() |> age!(30)
    assert :noop == UnconfirmedRetention.reap(user)
    assert user_exists?(user.id)
  end

  test "organization owner is skipped (isolated from the sole-admin-workspace guard)" do
    user = unconfirmed_user_fixture() |> age!(30)
    org = create_organization!(user)

    # Organization :create also runs CreateSharedWorkspace, which makes
    # `user` the sole admin of the org's shared workspace — that alone
    # would trip the sole-admin-workspace guard regardless of the org
    # guard under test. Add a second admin to that workspace so the
    # sole-admin-workspace check passes, isolating this test to
    # owns_org?/1 specifically.
    other_admin = unconfirmed_user_fixture()

    [shared_ws] =
      Magus.Workspaces.Workspace
      |> Ash.Query.filter(organization_id == ^org.id)
      |> Ash.read!(authorize?: false)

    workspace_member(user_id: other_admin.id, workspace_id: shared_ws.id, role: :admin)

    assert :skipped == UnconfirmedRetention.reap(user)
    assert user_exists?(user.id)
  end

  test "sole-admin workspace holder is skipped" do
    user = unconfirmed_user_fixture() |> age!(30)
    ensure_workspace_plan(user)
    _ws = generate(workspace(actor: user))

    assert :skipped == UnconfirmedRetention.reap(user)
    assert user_exists?(user.id)
  end

  test "user owning a file is skipped before any destruction" do
    user = unconfirmed_user_fixture() |> age!(30)
    file = generate(file(user_id: user.id))

    assert :skipped == UnconfirmedRetention.reap(user)
    assert user_exists?(user.id)
    assert {:ok, _} = Ash.get(Magus.Files.File, file.id, authorize?: false)
  end

  test "user owning a conversation with a complete agent reply is skipped before any destruction" do
    user = unconfirmed_user_fixture() |> age!(30)
    conv = generate(conversation(actor: user))
    add_complete_agent_message!(conv.id)

    assert :skipped == UnconfirmedRetention.reap(user)
    assert user_exists?(user.id)
    assert {:ok, _} = Ash.get(Magus.Chat.Conversation, conv.id, authorize?: false)
  end

  test "user owning a conversation with only their own (gate-blocked) message is still reaped" do
    # Mirrors the confirmation gate's own flow: the SPA creates the
    # conversation before the first message is sent, then blocks the turn
    # (no agent reply is ever persisted). A conversation holding only that
    # blocked user message is not real content worth protecting — treating
    # it as such would make the reaper's primary target population (bots
    # that attempted chat and got blocked) permanently unreapable. See
    # owns_conversations?/1 in lib/magus/accounts/unconfirmed_retention.ex.
    user = unconfirmed_user_fixture() |> age!(30)
    conv = generate(conversation(actor: user))
    _user_msg = generate(message(actor: user, conversation_id: conv.id))

    assert :deleted == UnconfirmedRetention.reap(user)
    refute user_exists?(user.id)
  end

  test "user owning a brain resource is skipped before any destruction" do
    user = unconfirmed_user_fixture() |> age!(30)
    brain = generate(brain(user_id: user.id))

    assert :skipped == UnconfirmedRetention.reap(user)
    assert user_exists?(user.id)
    assert {:ok, _} = Ash.get(Magus.Brain.BrainResource, brain.id, authorize?: false)
  end

  test "a soft-deleted (trashed) conversation does not block the reap" do
    # Mirrors AccountDeletion.cleanup_user_conversation_external_resources/1's
    # own filter (is_nil(deleted_at)): a trashed conversation is not among
    # what that pre-transaction cleanup would destroy, so it must not count
    # as owned content either. Gives the conversation a complete agent
    # reply first — the kind of content that WOULD block the reap per
    # owns_conversations?/1 if it weren't trashed — so this test actually
    # exercises the deleted_at exclusion rather than passing trivially
    # because a bare conversation doesn't count as owned content anyway.
    user = unconfirmed_user_fixture() |> age!(30)
    conv = generate(conversation(actor: user))
    add_complete_agent_message!(conv.id)

    conv
    |> Ash.Changeset.for_update(:soft_delete, %{}, authorize?: false)
    |> Ash.update!()

    assert :deleted == UnconfirmedRetention.reap(user)
    refute user_exists?(user.id)
  end

  test "user confirmed between scheduling and delete: data (row, conversation, file, prompt) intact" do
    user = unconfirmed_user_fixture() |> age!(30)
    conv = generate(conversation(actor: user))
    file = generate(file(user_id: user.id))
    prompt = generate(prompt(actor: user))

    # Simulate the race: the DB row confirms after the reaper already loaded
    # `user` into memory (still showing confirmed_at: nil), then
    # AccountDeletion.execute/2 is called directly with that stale struct.
    # This deliberately bypasses UnconfirmedRetention.reap/1's own
    # content-ownership skip (covered by the "user owning a
    # file/conversation/brain resource is skipped" tests above) so it
    # exercises AccountDeletion's own precondition protection in
    # isolation: either its fresh pre-cleanup confirmed_at re-check or its
    # transaction's conditional row DELETE must catch this, and neither
    # must destroy the conversation/file/prompt on the way.
    confirm!(user)

    assert {:error, :precondition_failed} =
             AccountDeletion.execute(user, require_unconfirmed: true)

    assert user_exists?(user.id)
    assert {:ok, _} = Ash.get(Magus.Chat.Conversation, conv.id, authorize?: false)
    assert {:ok, _} = Ash.get(Magus.Files.File, file.id, authorize?: false)
    assert {:ok, _} = Ash.get(Magus.Library.Prompt, prompt.id, authorize?: false)
  end

  test "user deleted between the worker's read and reap/1's reload: returns :noop, no crash" do
    user = unconfirmed_user_fixture() |> age!(30)

    # Simulate the row disappearing (e.g. a concurrent delete) between
    # whatever read produced this `user` struct and reap/1 reloading it.
    Repo.delete_all(from(u in "users", where: u.id == type(^user.id, :binary_id)))

    assert :noop == UnconfirmedRetention.reap(user)
  end

  describe ":reap_unconfirmed AshOban trigger (end-to-end)" do
    test "running the trigger reaps an eligible user, and the job completes cleanly even " <>
           "though the after_action deletes the subject row" do
      user = unconfirmed_user_fixture() |> age!(30)

      # Schedules + drains the :unconfirmed_reap queue in-process
      # (drain_queues?: true). The worker reads the user fresh via
      # :read_for_reaping, runs :reap_if_unconfirmed, whose after_action
      # calls UnconfirmedRetention.reap/1 and deletes the row out from
      # under Ash — asserting %{failure: 0} proves the job still
      # completes cleanly despite that (the action returns {:ok, user}
      # from the after_action rather than letting AshOban reload the now
      # gone record; see the trigger's comment in user.ex).
      assert %{failure: 0} =
               AshOban.Test.schedule_and_run_triggers({User, :reap_unconfirmed})

      refute user_exists?(user.id)
    end

    test "a fresh unconfirmed user does not match the trigger's where filter " <>
           "(the ago(1, :day) scheduler floor)" do
      user = unconfirmed_user_fixture()

      AshOban.Test.refute_would_schedule(user, :reap_unconfirmed)
    end
  end

  describe "validate_config!/0" do
    test "accepts nil (reaping disabled)" do
      Application.put_env(:magus, :unconfirmed_account_ttl_days, nil)
      assert :ok == UnconfirmedRetention.validate_config!()
    end

    test "accepts a positive integer" do
      Application.put_env(:magus, :unconfirmed_account_ttl_days, 7)
      assert :ok == UnconfirmedRetention.validate_config!()
    end

    test "rejects zero and negatives" do
      Application.put_env(:magus, :unconfirmed_account_ttl_days, 0)

      assert_raise RuntimeError,
                   ~r/unconfirmed_account_ttl_days/,
                   &UnconfirmedRetention.validate_config!/0

      Application.put_env(:magus, :unconfirmed_account_ttl_days, -1)

      assert_raise RuntimeError,
                   ~r/unconfirmed_account_ttl_days/,
                   &UnconfirmedRetention.validate_config!/0
    end
  end
end
