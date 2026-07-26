defmodule Magus.Agents.Tools.Remote.NoPersistTest do
  use ExUnit.Case, async: true

  test "ConversationAgent base config carries no remote/local tools" do
    # Base tools are empty in the agent definition; local tools only ever arrive
    # per-turn via run_tools, so a thawed agent (restored from base config)
    # cannot expose read_file without a live connection re-injecting it.
    strategy_opts = Magus.Agents.ConversationAgent.strategy_opts()
    base_tools = Keyword.get(strategy_opts, :tools, [])
    refute Magus.Agents.Tools.Remote.ReadFile in base_tools
  end
end
