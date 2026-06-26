defmodule Magus.Agents.Tools.ToolBuilderTest do
  @moduledoc """
  Tests for the ToolBuilder module.

  Tests cover:
  - Base tool set construction for different modes
  - Task conversation tool set adjustments
  - Skill tool resolution
  - Agent isolation flags
  - Tool context construction
  - ReqLLM tool conversion
  - Agent category filtering
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.ToolBuilder
  alias Magus.Agents.Tools.Web.{WebSearch, WebFetch}
  alias Magus.Agents.Tools.Skills.LoadSkill
  alias Magus.Agents.Tools.Memory.SearchMemories
  alias Magus.Agents.Tools.Sandbox.RunCode
  alias Magus.Agents.Tools.Tasks.{SpawnTask, SpawnSubAgent, ReportToParent, CompleteTask}
  alias Magus.Agents.Tools.Autonomy.{ListInboxEvents, DismissEvent, SetNextWakeup}
  alias Magus.Agents.Tools.{DiceRoll, Rag}
  alias Magus.SuperBrain.Tools.Search, as: SuperBrainSearch

  describe "build_tools/4" do
    test "returns base tools for :chat mode" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      conversation = Ash.load!(conversation, [:user], authorize?: false)

      {tools, _tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)
      tool_names = Enum.map(tools, & &1.name())

      assert "load_skill" in tool_names
      assert "tool_search" in tool_names
      assert "load_tool" in tool_names
      assert "search_files" in tool_names
    end

    test "returns empty tools when supports_tools is false" do
      assert {[], %{}} = ToolBuilder.build_tools(:chat, %{}, false, nil)
    end

    test "adds web_search for :search mode" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      conversation = Ash.load!(conversation, [:user], authorize?: false)

      {tools, _tool_contexts} = ToolBuilder.build_tools(:search, conversation, true, nil)

      assert WebSearch in tools
    end

    test "does not include web_search in :chat mode without skill_tools" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      conversation = Ash.load!(conversation, [:user], authorize?: false)

      {tools, _tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

      refute WebSearch in tools
    end

    test "removes spawn_sub_agent for task conversations" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{is_task_conversation: true}, actor: user)

      conversation = Ash.load!(conversation, [:user], authorize?: false)

      {tools, _tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

      refute SpawnSubAgent in tools
      assert ReportToParent in tools
      assert CompleteTask in tools
    end

    test "excludes task-only tools for non-task conversations" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      conversation = Ash.load!(conversation, [:user], authorize?: false)

      {tools, _tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

      assert SpawnSubAgent in tools
      assert SpawnTask in tools
      refute ReportToParent in tools
      refute CompleteTask in tools
    end

    test "includes skill-gated tools when skill_tools declares them" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{skill_tools: ["web_search"]}, actor: user)

      conversation = Ash.load!(conversation, [:user], authorize?: false)

      {tools, tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

      assert WebSearch in tools
      assert Map.has_key?(tool_contexts, WebSearch)
    end

    test "gracefully handles nil skill_tools" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      conversation = Ash.load!(conversation, [:user], authorize?: false)

      assert conversation.skill_tools == nil

      {tools, _tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

      assert is_list(tools)
      assert length(tools) > 0
    end

    test "deduplicates tools already in base list" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{skill_tools: ["roll_dice"]}, actor: user)

      conversation = Ash.load!(conversation, [:user], authorize?: false)

      {tools, _tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

      dice_roll_count = Enum.count(tools, &(&1 == DiceRoll))
      assert dice_roll_count == 1
    end

    test "includes autonomy tools in the base tool set" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      conversation = Ash.load!(conversation, [:user], authorize?: false)

      {tools, _tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

      assert ListInboxEvents in tools
      assert DismissEvent in tools
      assert SetNextWakeup in tools
    end

    test "includes super_brain_search in the main tool set for regular conversations" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)
      conversation = Ash.load!(conversation, [:user], authorize?: false)

      {tools, _tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

      assert SuperBrainSearch in tools
    end

    test "includes super_brain_search in the sub-agent tool set for sub-agent conversations" do
      user = generate(user())
      {:ok, parent} = Chat.create_conversation(%{}, actor: user)

      {:ok, conversation} =
        Chat.create_conversation(
          %{is_task_conversation: true, parent_conversation_id: parent.id},
          actor: user
        )

      conversation = Ash.load!(conversation, [:user], authorize?: false)

      {tools, _tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

      assert SuperBrainSearch in tools
    end

    test "ignores unknown skill tool names" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(
          %{skill_tools: ["nonexistent_tool", "web_search"]},
          actor: user
        )

      conversation = Ash.load!(conversation, [:user], authorize?: false)

      {tools, _tool_contexts} = ToolBuilder.build_tools(:chat, conversation, true, nil)

      assert WebSearch in tools
    end
  end

  describe "build_tool_context/3" do
    test "includes user and conversation metadata" do
      ctx = ToolBuilder.build_tool_context("user-123", "conv-456", %{folder_id: "folder-789"})

      assert ctx.user_id == "user-123"
      assert ctx.conversation_id == "conv-456"
      assert ctx[:folder_id] == "folder-789"
      assert ctx[:__conversation_id__] == "conv-456"
    end

    test "includes default isolation flags" do
      ctx = ToolBuilder.build_tool_context("user-123", "conv-456", %{})

      assert ctx[:can_read_global_memories] == true
      assert ctx[:can_write_global_memories] == true
      assert ctx[:can_access_global_files] == true
    end

    test "merges custom isolation flags from opts" do
      ctx =
        ToolBuilder.build_tool_context("user-123", "conv-456", %{
          can_read_global_memories: false,
          can_write_global_memories: false
        })

      assert ctx[:can_read_global_memories] == false
      assert ctx[:can_write_global_memories] == false
      assert ctx[:can_access_global_files] == true
    end
  end

  describe "extract_agent_isolation_flags/1" do
    test "returns default flags when agent is nil" do
      flags = ToolBuilder.extract_agent_isolation_flags(nil)

      assert flags.can_read_global_memories == true
      assert flags.can_write_global_memories == true
      assert flags.can_access_global_files == true
    end

    test "returns default flags for Ash.NotLoaded" do
      flags = ToolBuilder.extract_agent_isolation_flags(%Ash.NotLoaded{})

      assert flags.can_read_global_memories == true
      assert flags.can_write_global_memories == true
      assert flags.can_access_global_files == true
    end

    test "extracts flags from agent map" do
      agent = %{
        can_read_global_memories: false,
        can_write_global_memories: true,
        can_access_global_files: false,
        can_access_knowledge: false
      }

      flags = ToolBuilder.extract_agent_isolation_flags(agent)

      assert flags.can_read_global_memories == false
      assert flags.can_write_global_memories == true
      assert flags.can_access_global_files == false
      assert flags.can_access_knowledge == false
    end

    test "returns default flags for unrecognized values" do
      flags = ToolBuilder.extract_agent_isolation_flags(:something_else)

      assert flags.can_read_global_memories == true
      assert flags.can_write_global_memories == true
      assert flags.can_access_global_files == true
      assert flags.can_access_knowledge == true
    end
  end

  describe "resolve_skill_tools/1" do
    test "resolves known skill tool names to modules" do
      tools = ToolBuilder.resolve_skill_tools(["web_search", "run_code"])

      assert WebSearch in tools
      assert RunCode in tools
    end

    test "returns empty list for nil" do
      assert ToolBuilder.resolve_skill_tools(nil) == []
    end

    test "returns empty list for empty list" do
      assert ToolBuilder.resolve_skill_tools([]) == []
    end

    test "ignores unknown tool names" do
      tools = ToolBuilder.resolve_skill_tools(["unknown_tool", "web_fetch"])

      assert WebFetch in tools
      assert length(tools) == 1
    end
  end

  describe "skill_tool_mapping/0" do
    test "returns the full skill tool mapping" do
      mapping = ToolBuilder.skill_tool_mapping()

      assert is_map(mapping)
      assert Map.get(mapping, "web_search") == WebSearch
      assert Map.get(mapping, "load_skill") == LoadSkill
      assert Map.get(mapping, "run_code") == RunCode
    end
  end

  describe "tool_to_category/0" do
    test "returns tool category mapping" do
      categories = ToolBuilder.tool_to_category()

      assert Map.get(categories, WebSearch) == :web
      assert Map.get(categories, RunCode) == :code
      assert Map.get(categories, SearchMemories) == :memory
      assert Map.get(categories, Rag) == :files
      assert Map.get(categories, LoadSkill) == :skills
    end
  end

  describe "filter_by_agent_categories/2" do
    test "removes tools from disabled categories" do
      tools = [WebSearch, WebFetch, RunCode, DiceRoll, SearchMemories]

      agent = %{disabled_tool_categories: [:web, :code]}
      filtered = ToolBuilder.filter_by_agent_categories(tools, agent)

      refute WebSearch in filtered
      refute WebFetch in filtered
      refute RunCode in filtered
      # DiceRoll is uncategorized, should remain
      assert DiceRoll in filtered
      # SearchMemories is :memory, not disabled
      assert SearchMemories in filtered
    end

    test "returns all tools when agent is nil" do
      tools = [WebSearch, RunCode, DiceRoll]

      assert ToolBuilder.filter_by_agent_categories(tools, nil) == tools
    end

    test "returns all tools when disabled_tool_categories is empty" do
      tools = [WebSearch, RunCode, DiceRoll]
      agent = %{disabled_tool_categories: []}

      assert ToolBuilder.filter_by_agent_categories(tools, agent) == tools
    end
  end

  describe "build_reqllm_tools/2" do
    test "converts action modules to ReqLLM tool format" do
      tool_contexts = %{DiceRoll => %{user_id: "user-123"}}
      reqllm_tools = ToolBuilder.build_reqllm_tools([DiceRoll], tool_contexts)

      assert length(reqllm_tools) == 1
      [tool] = reqllm_tools
      assert tool.name == "roll_dice"
    end

    test "returns empty list for empty input" do
      assert ToolBuilder.build_reqllm_tools([], %{}) == []
    end
  end
end
