defmodule Magus.Accounts.UnconfirmedRetentionTest do
  @moduledoc """
  Task 5 (signup-abuse-hardening): the unconfirmed-account reaper deletes
  password signups that never confirmed their email past the configured
  TTL, skips users who own structure (organization, sole-admin workspace),
  and is race-safe against a confirm racing the delete (the conditional
  final-row DELETE inside AccountDeletion's transaction — see
  `Magus.Accounts.AccountDeletion.PreconditionFailed`).
  """
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Accounts.AccountDeletion
  alias Magus.Accounts.UnconfirmedRetention
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

  test "organization owner is skipped" do
    user = unconfirmed_user_fixture() |> age!(30)
    _org = create_organization!(user)

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

  test "user confirmed between scheduling and delete: transaction rolls back, data intact" do
    user = unconfirmed_user_fixture() |> age!(30)
    # Simulate the race: the DB row confirms after the reaper already loaded
    # `user` into memory (still showing confirmed_at: nil), then the reaper's
    # delete path runs against that stale struct. The conditional DELETE
    # inside AccountDeletion's transaction is what catches this at the row.
    confirm!(user)

    assert {:error, :precondition_failed} =
             AccountDeletion.execute(user, require_unconfirmed: true)

    assert user_exists?(user.id)
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
