defmodule Magus.Agents.Clients.LLMCredentialTest do
  use Magus.DataCase, async: false
  import Magus.Generators
  alias Magus.Agents.Clients.LLM

  setup do
    Magus.DataCase.clear_catalog!()
    user = generate(user())

    {:ok, provider} =
      Magus.Models.create_owned_provider(
        %{name: "Mine", req_llm_id: "anthropic", api_key: "sk-owner"},
        actor: user
      )

    {:ok, model} =
      Magus.Chat.create_owned_model(
        %{name: "C", model_id: "claude-x", model_provider_id: provider.id},
        actor: user
      )

    %{user: user, model: model}
  end

  test "owner id in credential_actor_id yields rewritten spec + key, opt popped", %{
    user: user,
    model: model
  } do
    {spec, opts} = LLM.provider_options(model.key, credential_actor_id: user.id, temperature: 0.5)
    assert spec == "anthropic:claude-x"
    assert opts[:api_key] == "sk-owner"
    refute Keyword.has_key?(opts, :credential_actor_id)
    assert opts[:temperature] == 0.5
  end

  test "absent or foreign actor id keeps safe fallback", %{model: model} do
    assert {key, opts} = LLM.provider_options(model.key, [])
    assert key == model.key
    refute opts[:api_key]

    other = generate(user())
    assert {key2, opts2} = LLM.provider_options(model.key, credential_actor_id: other.id)
    assert key2 == model.key
    refute opts2[:api_key]
  end

  test "non-binary model passes through" do
    assert {%{some: :map}, [a: 1]} =
             LLM.provider_options(%{some: :map}, a: 1, credential_actor_id: "x")
  end

  # ==========================================================================
  # Step 5: end-to-end wiring assertion (Config level).
  #
  # The integration harness (test/magus/agents/integration_test.exs) exercises
  # plugin signal routing but never drives a full worker turn through the mock
  # LLM client to capture the exact opts a turn passes, so there is no
  # lightweight seam to assert `credential_actor_id` on the mock. Per the
  # brief, we assert at the Config level instead: the react runtime Config is
  # the transport that carries the strategy's `llm_opts` (where process_start
  # injects `credential_actor_id`) forward into every turn's stream/generate
  # call via `Config.llm_opts/1`. This test pins that transport end to end.
  # ==========================================================================
  test "react runtime Config carries credential_actor_id from llm_opts into Config.llm_opts/1",
       %{model: model} do
    alias Jido.AI.Reasoning.ReAct.Config

    config =
      Config.new(%{
        model: model.key,
        llm_opts: [credential_actor_id: "owner-123"]
      })

    opts = Config.llm_opts(config)
    assert opts[:credential_actor_id] == "owner-123"
  end
end
