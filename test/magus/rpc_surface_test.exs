defmodule Magus.RpcSurfaceTest do
  @moduledoc """
  Pins the RPC-exposed action surface of Model and Provider.

  These resources deliberately expose ONLY read/curation and owned CRUD actions
  over the AshTypescript RPC boundary. Admin/write actions (global create/update,
  enable/disable, seeding, etc.) must NOT be reachable from untrusted clients.

  If this test fails, a `typescript_rpc` block gained or lost an `rpc_action`.
  Adding a write/admin action over RPC needs a security review first. See
  docs/superpowers/specs/2026-07-02-user-model-phase-2b2b-hardstop-gate-clone-design.md
  """
  use ExUnit.Case, async: true

  # Expected BACKING action names (not the public rpc_action names).
  @model_expected ~w(list_active list_image_generation list_video_generation create_owned owned destroy_owned)a
  @provider_expected ~w(owned create_owned update_owned destroy_owned validate list_remote_models)a

  @spec_ref "docs/superpowers/specs/2026-07-02-user-model-phase-2b2b-hardstop-gate-clone-design.md"

  test "Model RPC surface is pinned" do
    assert exposed_actions(Magus.Chat, Magus.Chat.Model) |> Enum.sort() ==
             Enum.sort(@model_expected),
           "Model's RPC surface changed. Adding write/admin actions over RPC needs a security review (see #{@spec_ref})."
  end

  test "Provider RPC surface is pinned" do
    assert exposed_actions(Magus.Models, Magus.Models.Provider) |> Enum.sort() ==
             Enum.sort(@provider_expected),
           "Provider's RPC surface changed. Adding write/admin actions over RPC needs a security review (see #{@spec_ref})."
  end

  # Returns the BACKING action names (atoms) exposed via the `typescript_rpc`
  # DSL for `resource` on `domain`. `AshTypescript.Rpc.Info.typescript_rpc/1`
  # returns a list of `%AshTypescript.Rpc.Resource{}` entities; each carries
  # `rpc_actions`, whose `.action` is the backing action (`.name` is the public
  # rpc name we intentionally ignore here).
  defp exposed_actions(domain, resource) do
    domain
    |> AshTypescript.Rpc.Info.typescript_rpc()
    |> Enum.find(&(&1.resource == resource))
    |> case do
      nil -> []
      %{rpc_actions: rpc_actions} -> Enum.map(rpc_actions, & &1.action)
    end
  end
end
