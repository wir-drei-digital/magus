defmodule Magus.Organizations.MemberRpcTest do
  use Magus.DataCase, async: true

  test "member management actions are exposed as rpc_actions" do
    rpc_actions =
      Magus.Organizations
      |> AshTypescript.Rpc.Info.typescript_rpc()
      |> Enum.flat_map(fn resource -> resource.rpc_actions end)
      |> Enum.map(& &1.name)

    for name <- [
          :change_org_member_role,
          :remove_org_member,
          :transfer_org_ownership,
          :resend_org_invite
        ] do
      assert name in rpc_actions
    end
  end
end
