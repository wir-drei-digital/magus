defmodule Magus.Organizations.SeatSyncTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Organizations

  defmodule TestSink do
    @behaviour Magus.Organizations.SeatSync
    @impl true
    def on_member_activated(member_id) do
      send(Application.get_env(:magus, :seat_sync_test_pid), {:activated, member_id})
      :ok
    end

    @impl true
    def on_member_removed(member_id) do
      send(Application.get_env(:magus, :seat_sync_test_pid), {:removed, member_id})
      :ok
    end
  end

  setup do
    Application.put_env(:magus, :seat_sync_test_pid, self())
    Application.put_env(:magus, Magus.Organizations.SeatSync, impl: TestSink)

    on_exit(fn ->
      Application.delete_env(:magus, Magus.Organizations.SeatSync)
      Application.delete_env(:magus, :seat_sync_test_pid)
    end)

    :ok
  end

  test "activating and removing a member fires the seam" do
    owner = generate(user())
    ensure_workspace_plan(owner)
    {:ok, org} = Organizations.create_organization(%{name: "S", slug: "seat-org"}, actor: owner)
    {:ok, invite} = Organizations.invite_org_member(org.id, "seat@test.com", actor: owner)

    joiner = generate(user())
    {:ok, member} = Organizations.accept_invite(invite.invite_token, actor: joiner)
    assert_receive {:activated, member_id} when member_id == member.id

    {:ok, _} = Organizations.remove_org_member(member, actor: owner)
    assert_receive {:removed, removed_id} when removed_id == member.id
  end
end
