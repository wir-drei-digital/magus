defmodule Magus.Agents.Plugins.Support.PreflightActorTest do
  @moduledoc """
  Covers the acting-user threading that Preflight/MediaBypass do into
  `Magus.Models.Resolver.resolve/2` (Task 1, phase 2b-2a).

  Preflight's `build_react_signal/3` is only invocable with heavyweight agent
  scaffolding (active subscription, real conversation, full LLM-context
  assembly). The threading contract itself is: the acting-user id the call
  sites compute scopes owned-model visibility in the resolver. We assert that
  contract directly at the resolver, using the same bare-binary-id shape the
  call sites pass. The preflight-level end-to-end path is covered by Task 2's
  end-to-end test.
  """
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Models.Resolver

  setup do
    Magus.DataCase.clear_catalog!()
    owner = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk"},
        actor: owner
      )

    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{name: "C", model_id: "claude-x", model_provider_id: provider.id},
        actor: owner
      )

    %{owner: owner, model: model}
  end

  test "the owner's acting id (bare binary) resolves their owned model", %{
    owner: owner,
    model: model
  } do
    {:ok, res} =
      Resolver.resolve(owner.id, %{model_keys: %{chat: model.key}, mode: :chat})

    assert res.model.key == model.key
    assert res.access_source == :owned
    assert res.credential_owner_user_id == owner.id
    assert res.cost_source == :byok
  end

  test "a different acting id (bare binary) cannot see the owned model, so it degrades", %{
    model: model
  } do
    other = generate(user())

    {:ok, res} =
      Resolver.resolve(other.id, %{model_keys: %{chat: model.key}, mode: :chat})

    refute res.model.key == model.key
    assert res.access_source == :global
  end
end
