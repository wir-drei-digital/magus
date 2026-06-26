defmodule Magus.Usage.SeatGrantSyncTest do
  @moduledoc """
  `Magus.Usage.SeatGrantSync` is the open-core seam for propagating a sponsor's
  plan change to their commercial seat grants. Core default is a no-op (OSS has
  no paid-seat sponsorship); the billing edition wires the Billing impl.
  """
  # async: false — reads/writes the global :magus, SeatGrantSync app env.
  use ExUnit.Case, async: false

  alias Magus.Usage.SeatGrantSync

  setup do
    original = Application.get_env(:magus, SeatGrantSync)

    on_exit(fn ->
      if original,
        do: Application.put_env(:magus, SeatGrantSync, original),
        else: Application.delete_env(:magus, SeatGrantSync)
    end)

    :ok
  end

  describe "default (no billing edition)" do
    test "mirror_plan/2 and revoke_all/1 are no-ops returning :ok" do
      Application.delete_env(:magus, SeatGrantSync)

      assert SeatGrantSync.mirror_plan("sponsor-id", "plan-id") == :ok
      assert SeatGrantSync.revoke_all("sponsor-id") == :ok
    end
  end

  describe "configured impl" do
    defmodule FakeSync do
      @behaviour Magus.Usage.SeatGrantSync
      @impl true
      def mirror_plan(sponsor_user_id, usage_plan_id) do
        send(self(), {:mirror, sponsor_user_id, usage_plan_id})
        :ok
      end

      @impl true
      def revoke_all(sponsor_user_id) do
        send(self(), {:revoke, sponsor_user_id})
        :ok
      end
    end

    test "delegates to the configured impl" do
      Application.put_env(:magus, SeatGrantSync, impl: FakeSync)

      assert SeatGrantSync.mirror_plan("u1", "p1") == :ok
      assert_received {:mirror, "u1", "p1"}

      assert SeatGrantSync.revoke_all("u1") == :ok
      assert_received {:revoke, "u1"}
    end
  end
end
