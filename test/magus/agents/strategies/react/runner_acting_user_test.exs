defmodule Magus.Agents.Strategies.React.RunnerActingUserTest do
  # Phase 3 Task 2: unit-test the actor-resolution helper the runner uses for
  # execute_mcp_tool. The helper returns the acting user when present, otherwise
  # falls back to the owner (user_id). Full dispatch is covered by Task 4's
  # integration test.
  use ExUnit.Case, async: true

  alias Magus.Agents.Strategies.ReactStrategy.Runner

  test "prefers acting_user_id over the owner user_id" do
    assert Runner.mcp_acting_user_id(%{acting_user_id: "A", user_id: "O"}) == "A"
  end

  test "falls back to user_id (owner) when acting_user_id is absent" do
    assert Runner.mcp_acting_user_id(%{user_id: "O"}) == "O"
  end

  test "falls back to user_id (owner) when acting_user_id is nil" do
    assert Runner.mcp_acting_user_id(%{acting_user_id: nil, user_id: "O"}) == "O"
  end

  test "resolves string-keyed acting_user_id" do
    assert Runner.mcp_acting_user_id(%{"acting_user_id" => "A", "user_id" => "O"}) == "A"
  end

  test "resolves string-keyed user_id fallback" do
    assert Runner.mcp_acting_user_id(%{"user_id" => "O"}) == "O"
  end

  test "returns nil when neither is present" do
    assert Runner.mcp_acting_user_id(%{}) == nil
  end
end
