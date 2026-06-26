defmodule Magus.MCP.Phase3ActingUserTest do
  @moduledoc """
  Phase 3 consolidating integration test: acting-user scoping across the real
  seams (no live LLM).

  Three slices, all driving production code paths:

    * **Autonomy / heartbeat** (`build_run_signal_payload/1`): a run acts as its
      initiator (`AgentRun.initiator_user_id`, the agent's owning user), never a
      bare `ai_actor()`. nil initiator falls through to the owner fallback.
    * **Solo** (`ToolBuilder.build_tools`): a solo conversation whose owner owns
      the loaded MCP server resolves the owner's tool exactly as Phase 2 did
      (acting_user_id == owner.id, since author == owner). No regression.
    * **Multiplayer** (`ToolBuilder.build_tools`): an owner-owned conversation
      with an accepted `member` who owns their OWN private MCP server. The
      member's turn (acting_user_id = member.id) resolves the member's tool into
      the MCP carrier; the owner's turn (acting_user_id = owner.id) does NOT,
      because the owner has no access to the member's server. This is per-member
      MCP scoping end-to-end.

  The acting-user scoping is **server-access-based**: `Catalog.resolve/2` gates
  MCP tools on whether the acting user can read the SERVER, not on conversation
  membership. We still make `member` a real accepted `ConversationMember` for
  realism, so the multiplayer slice mirrors a genuine shared conversation; the
  load-bearing boundary is the per-server access check, proven non-vacuous by
  using two distinct generated users where only the server's owner has access.

  Return-shape note: `build_tools/6` returns `{tools, tool_contexts}`. The MCP
  carrier is seeded into the base tool context, so it appears identically on
  every per-tool context (Preflight's `shared_tool_context/1` intersection
  carries it into `base_tool_context` -> `effective_tool_context` ->
  `context[:__mcp_tools__]`). We read it back the same way the Task-2 builder
  tests do.
  """

  use Magus.ResourceCase, async: false

  import Magus.Generators

  alias Magus.Agents.RunOrchestrator
  alias Magus.Agents.Tools.ToolBuilder
  alias Magus.Chat

  # Mirror of the Task-2 builder tests: pull the `__mcp_tools__` carrier off any
  # per-tool context (they all share the base map).
  defp mcp_carrier(tool_contexts) do
    tool_contexts
    |> Map.values()
    |> Enum.filter(&is_map/1)
    |> Enum.find_value([], fn ctx -> Map.get(ctx, :__mcp_tools__) end)
  end

  defp coined_in_carrier?(tool_contexts, coined_name) do
    Enum.any?(mcp_carrier(tool_contexts), &(&1.coined_name == coined_name))
  end

  # A personal `:none` MCP server owned by `user`, carrying one cached tool.
  # `:none` auth + personal ownership means a different user has NO access to it
  # (no resource_accesses grant), so the access boundary is genuine.
  defp personal_server_with_tool(user, handle, remote_name) do
    {:ok, server} =
      Magus.MCP.create_server(
        %{
          name: "Server #{handle}",
          handle: handle,
          url: "https://example.test",
          auth_type: :none
        },
        actor: user
      )

    {:ok, server} =
      Magus.MCP.update_server_cached_tools(
        server,
        %{
          cached_tools: [
            %{
              "name" => remote_name,
              "description" => "",
              "input_schema" => %{"type" => "object", "properties" => %{}},
              "annotations" => %{}
            }
          ]
        },
        actor: user
      )

    server
  end

  describe "build_run_signal_payload/1 acting_user_id (autonomy)" do
    test "threads initiator_user_id (the agent owner) as the acting user" do
      initiator_id = Ecto.UUID.generate()

      run = %{
        id: Ecto.UUID.generate(),
        objective: "do the thing",
        request_id: Ecto.UUID.generate(),
        kind: :consult,
        source: :heartbeat,
        source_conversation_id: Ecto.UUID.generate(),
        source_message_id: nil,
        target_agent_id: Ecto.UUID.generate(),
        target_conversation_id: Ecto.UUID.generate(),
        initiator_user_id: initiator_id,
        model_key: nil
      }

      payload = RunOrchestrator.build_run_signal_payload(run)

      assert payload.acting_user_id == initiator_id
      # Additive: existing keys remain unchanged.
      assert payload.text == "do the thing"
      assert payload.mode == :chat
      assert payload.run_id == to_string(run.id)
    end

    test "owner fallback: nil initiator leaves acting_user_id nil so the run-path falls back to the owner" do
      run = %{
        id: Ecto.UUID.generate(),
        objective: "do the thing",
        request_id: Ecto.UUID.generate(),
        kind: :consult,
        source: :manual_trigger,
        source_conversation_id: Ecto.UUID.generate(),
        source_message_id: nil,
        target_agent_id: Ecto.UUID.generate(),
        target_conversation_id: Ecto.UUID.generate(),
        initiator_user_id: nil,
        model_key: nil
      }

      payload = RunOrchestrator.build_run_signal_payload(run)

      # nil here means Preflight.build_request_context falls back to
      # `state[:user_id]` (= conversation.user_id, the owner) — unchanged behavior.
      assert payload.acting_user_id == nil
    end
  end

  describe "solo conversation (no regression)" do
    test "owner's own MCP tool resolves when the owner is the acting user" do
      owner = generate(user())

      # The owner owns the MCP server whose tool is loaded into the conversation.
      _server = personal_server_with_tool(owner, "solo", "do")

      {:ok, conv} =
        Chat.create_conversation(%{title: "solo", loaded_tools: ["solo__do"]}, actor: owner)

      conv = Ash.load!(conv, [:user], authorize?: false)

      # In a solo conversation the author == owner, so acting_user_id == owner.id.
      {_tools, contexts} =
        ToolBuilder.build_tools(:chat, conv, true, nil, nil, acting_user_id: owner.id)

      assert coined_in_carrier?(contexts, "solo__do"),
             "solo: owner's own MCP tool must resolve into the carrier (Phase 2 behavior unchanged)"
    end
  end

  describe "multiplayer conversation (per-member MCP scoping)" do
    setup do
      owner = generate(user())
      member = generate(user())

      # `member` owns a PRIVATE `:none` server; `owner` has no grant on it.
      _member_server = personal_server_with_tool(member, "mem", "do")

      # Owner-owned conversation; the member's coined tool is loaded.
      {:ok, conv} =
        Chat.create_conversation(%{title: "mp", loaded_tools: ["mem__do"]}, actor: owner)

      # Make `member` a real accepted ConversationMember for realism. The
      # load-bearing assertion (acting_user_id scoping) does not depend on this —
      # Catalog.resolve checks access to the SERVER, not the conversation — but
      # this mirrors a genuine shared conversation. The membership row is seeded
      # with `authorize?: false` (the established pattern in
      # conversation_view_donut_authz_test.exs / policies_test.exs); the
      # acceptance is performed by the member themselves through the policy.
      {:ok, membership} =
        Chat.add_conversation_member(conv.id, member.id, %{invited_by_id: owner.id},
          authorize?: false
        )

      {:ok, _accepted} = Chat.accept_conversation_invitation(membership, actor: member)

      conv = Ash.load!(conv, [:user], authorize?: false)

      %{owner: owner, member: member, conv: conv}
    end

    test "the member's turn resolves the member's own MCP tool", %{member: member, conv: conv} do
      {_tools, member_contexts} =
        ToolBuilder.build_tools(:chat, conv, true, nil, nil, acting_user_id: member.id)

      assert coined_in_carrier?(member_contexts, "mem__do"),
             "member's turn: member can access their own server; carrier must include mem__do"
    end

    test "the owner's turn does NOT resolve the member's MCP tool", %{owner: owner, conv: conv} do
      {_tools, owner_contexts} =
        ToolBuilder.build_tools(:chat, conv, true, nil, nil, acting_user_id: owner.id)

      refute coined_in_carrier?(owner_contexts, "mem__do"),
             "owner's turn: owner lacks access to the member's private server; carrier must NOT include mem__do"
    end
  end
end
