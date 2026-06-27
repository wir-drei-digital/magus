defmodule Magus.Agents.Tools.ToolBuilder do
  @moduledoc """
  Builds tool sets for conversation agents based on mode, skills, and isolation flags.

  Answers the question "WHICH tools should be available?" without concerning
  itself with HOW those tools are run.

  ## Public API

  - `build_tools/4` - Build the tool list and tool contexts for a conversation
  - `build_tool_context/3` - Build a tool context map from user/conversation metadata
  - `build_reqllm_tools/2` - Convert Jido Action modules to ReqLLM tool format
  - `extract_agent_isolation_flags/1` - Extract isolation flags from a custom agent
  - `resolve_skill_tools/1` - Resolve skill tool name strings to modules
  - `filter_by_agent_categories/2` - Filter tools by agent's disabled categories
  - `skill_tool_mapping/0` - Return the full skill-to-module mapping
  - `tool_to_category/0` - Return the tool-to-category mapping
  """

  require Logger

  alias Magus.Agents.Actions.GenerateText

  # Tool imports
  alias Magus.Agents.Tools.{DiceRoll, Rag}
  alias Magus.Agents.Tools.Web.{WebFetch, WebSearch}
  alias Magus.Agents.Tools.Memory.{SearchMemories, SetMemory, ForgetMemory}

  alias Magus.Agents.Tools.Integrations.{
    SearchEntries,
    GetSourceStatus,
    HttpRequest,
    ConfigureApiIntegration
  }

  alias Magus.Agents.Tools.Jobs.{
    CreateJob,
    UpdateJob,
    ListJobs,
    StopJob,
    PauseJob,
    ResumeJob
  }

  alias Magus.Agents.Tools.Email.SendEmail
  alias Magus.Agents.Tools.Files.SearchAttachedDocs

  alias Magus.Agents.Tools.Conversations.{
    SearchConversationHistory,
    FetchConversationHistory
  }

  alias Magus.Agents.Tools.Library.{ListPrompts, CreatePrompt}
  alias Magus.Agents.Tools.Models.ListModels
  alias Magus.Agents.Tools.Skills.LoadSkill

  alias Magus.Agents.Tools.Tasks.{
    SpawnTask,
    SpawnSubAgent,
    AwaitSubAgents,
    FetchSubAgentTranscript,
    ReportToParent,
    CompleteTask,
    RequestApproval
  }

  alias Magus.Agents.Tools.Draft.{WriteDraft, ReadDraft}

  alias Magus.Agents.Tools.Brain.{
    ReadBrain,
    EditBrain
  }

  alias Magus.Agents.Tools.Media.{
    GenerateImage,
    GenerateVideo
  }

  alias Magus.Agents.Tools.Plan.{
    CreateTask,
    UpdateTask,
    ListTasks,
    ClearTasks
  }

  alias Magus.Agents.Tools.Threads.CreateThread

  alias Magus.Agents.Tools.Autonomy.{
    ListInboxEvents,
    DismissEvent,
    LinkInboxEvent,
    SetNextWakeup
  }

  alias Magus.Agents.Tools.Sandbox.{
    ExecCommand,
    FileDownload,
    FileEdit,
    FileList,
    FileRead,
    FileSearch,
    FileUpload,
    FileWrite,
    InstallPackages,
    RunCode,
    StartService
  }

  # Every sandbox-backed tool. Gated as a group on
  # `Magus.Sandbox.Provider.configured?/0` in build_tools/4.
  @sandbox_tools [
    ExecCommand,
    FileDownload,
    FileEdit,
    FileList,
    FileRead,
    FileSearch,
    FileUpload,
    FileWrite,
    InstallPackages,
    RunCode,
    StartService
  ]

  alias Magus.Agents.Tools.Files.ListWorkspaceTemplates
  alias Magus.Agents.Tools.Spreadsheet.{ReadSheet, WriteCells}

  alias Magus.SuperBrain.Tools.Search, as: SuperBrainSearch
  alias Magus.Agents.Tools.SuperBrain.PinFact

  alias Magus.Agents.Tools.Catalog
  alias Magus.Agents.Tools.Search.{ToolSearch, LoadTool}
  alias Magus.Agents.Tools.Search.ActorContext

  # Maps skill-declared tool name strings to their module.
  # Used by resolve_skill_tools/1 to add tools to conversations based on skill frontmatter.
  @skill_tool_mapping %{
    "tool_search" => ToolSearch,
    "load_tool" => LoadTool,
    "web_search" => WebSearch,
    "web_fetch" => WebFetch,
    "search_files" => Rag,
    "roll_dice" => DiceRoll,
    "load_skill" => LoadSkill,
    "run_code" => RunCode,
    "install_packages" => InstallPackages,
    "send_email" => SendEmail,
    "search_memories" => SearchMemories,
    "set_memory" => SetMemory,
    "forget_memory" => ForgetMemory,
    "create_job" => CreateJob,
    "update_job" => UpdateJob,
    "list_jobs" => ListJobs,
    "stop_job" => StopJob,
    "pause_job" => PauseJob,
    "resume_job" => ResumeJob,
    "search_conversation_history" => SearchConversationHistory,
    "fetch_conversation_history" => FetchConversationHistory,
    "exec_command" => ExecCommand,
    "sandbox_read_file" => FileRead,
    "sandbox_edit_file" => FileEdit,
    "sandbox_write_file" => FileWrite,
    "sandbox_search" => FileSearch,
    "sandbox_list_files" => FileList,
    "sandbox_download_file" => FileDownload,
    "sandbox_upload_file" => FileUpload,
    "start_service" => StartService,
    "spawn_task" => SpawnTask,
    "spawn_sub_agent" => SpawnSubAgent,
    "await_sub_agents" => AwaitSubAgents,
    "fetch_sub_agent_transcript" => FetchSubAgentTranscript,
    "report_to_parent" => ReportToParent,
    "complete_task" => CompleteTask,
    "write_draft" => WriteDraft,
    "read_draft" => ReadDraft,
    "list_models" => ListModels,
    "list_prompts" => ListPrompts,
    "create_prompt" => CreatePrompt,
    "create_task" => CreateTask,
    "update_task" => UpdateTask,
    "list_tasks" => ListTasks,
    "clear_tasks" => ClearTasks,
    "request_approval" => RequestApproval,
    "http_request" => HttpRequest,
    "configure_api_integration" => ConfigureApiIntegration,
    "create_thread" => CreateThread,
    "read_brain" => ReadBrain,
    "edit_brain" => EditBrain,
    "generate_image" => GenerateImage,
    "generate_video" => GenerateVideo,
    "read_sheet" => ReadSheet,
    "write_cells" => WriteCells
  }

  # Maps tool modules to their category for agent-level filtering.
  # Tools not listed here are always available (uncategorized).
  @tool_to_category %{
    WebSearch => :web,
    WebFetch => :web,
    RunCode => :code,
    ExecCommand => :code,
    InstallPackages => :code,
    FileRead => :code,
    FileEdit => :code,
    FileWrite => :code,
    FileSearch => :code,
    FileList => :code,
    FileDownload => :code,
    FileUpload => :code,
    StartService => :code,
    SearchMemories => :memory,
    SetMemory => :memory,
    ForgetMemory => :memory,
    Rag => :files,
    WriteDraft => :files,
    ReadDraft => :files,
    LoadSkill => :skills,
    SpawnTask => :tasks,
    SpawnSubAgent => :tasks,
    AwaitSubAgents => :tasks,
    FetchSubAgentTranscript => :tasks,
    ReportToParent => :tasks,
    CompleteTask => :tasks,
    ListPrompts => :library,
    CreatePrompt => :library,
    CreateTask => :plan,
    UpdateTask => :plan,
    ListTasks => :plan,
    ClearTasks => :plan,
    SearchEntries => :integrations,
    GetSourceStatus => :integrations,
    HttpRequest => :integrations,
    ConfigureApiIntegration => :integrations,
    ReadBrain => :brain,
    EditBrain => :brain,
    GenerateImage => :media,
    GenerateVideo => :media,
    ReadSheet => :files,
    WriteCells => :files
  }

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Returns the skill-to-module mapping.
  """
  def skill_tool_mapping, do: @skill_tool_mapping

  @doc """
  Returns the tool-to-category mapping.
  """
  def tool_to_category, do: @tool_to_category

  @doc """
  Builds the available tools and their contexts based on mode and model capabilities.
  Returns `{tools, tool_contexts}` tuple.

  An optional `custom_agent_override` can be passed to use a different agent config
  than `conversation.custom_agent` (used by MentionDispatcher).
  """
  def build_tools(
        mode,
        conversation,
        supports_tools?,
        active_draft_id,
        custom_agent_override \\ nil,
        opts \\ []
      )

  def build_tools(_mode, _conversation, false, _active_draft_id, _custom_agent_override, _opts),
    do: {[], %{}}

  def build_tools(mode, conversation, true, active_draft_id, custom_agent_override, opts) do
    agent_config = custom_agent_override || conversation.custom_agent
    isolation_flags = extract_agent_isolation_flags(agent_config)
    brain_id = Keyword.get(opts, :brain_id)
    brain_page_id = Keyword.get(opts, :brain_page_id)

    tool_context =
      Map.merge(isolation_flags, %{
        user_id: conversation.user_id,
        user: conversation.user,
        conversation_id: conversation.id,
        folder_id: conversation.folder_id,
        active_draft_id: active_draft_id,
        workspace_id: conversation.workspace_id,
        brain_id: brain_id,
        brain_page_id: brain_page_id,
        custom_agent_id:
          if(agent_config && !match?(%Ash.NotLoaded{}, agent_config), do: agent_config.id)
      })

    # Tier 1: Base tools (always available)
    main_tools = [
      ToolSearch,
      LoadTool,
      LoadSkill,
      WebSearch,
      WebFetch,
      Rag,
      SpawnTask,
      SpawnSubAgent,
      AwaitSubAgents,
      FetchSubAgentTranscript,
      RequestApproval,
      SearchMemories,
      SuperBrainSearch,
      SearchConversationHistory,
      FetchConversationHistory,
      PinFact,
      SetMemory,
      ForgetMemory,
      WriteDraft,
      ReadDraft,
      CreateTask,
      UpdateTask,
      ListTasks,
      ClearTasks,
      FileList,
      FileDownload,
      ListWorkspaceTemplates,
      ReadSheet,
      WriteCells,
      # Autonomy
      ListInboxEvents,
      DismissEvent,
      LinkInboxEvent,
      SetNextWakeup
    ]

    sub_agent_tools = [
      ToolSearch,
      LoadTool,
      LoadSkill,
      WebSearch,
      WebFetch,
      Rag,
      SearchMemories,
      SuperBrainSearch,
      PinFact,
      SetMemory,
      ForgetMemory
    ]

    tools =
      cond do
        # Home conversations (task conversations bound to a custom agent and with
        # no parent) are the venue for autonomous heartbeat / manual-trigger runs
        # and need the autonomy tools (list_inbox_events, dismiss_event,
        # set_next_wakeup) plus the regular main toolset to act on their inbox.
        conversation.is_task_conversation and
          is_nil(conversation.parent_conversation_id) and
            not is_nil(conversation.custom_agent_id) ->
          main_tools

        conversation.is_task_conversation ->
          sub_agent_tools

        true ->
          main_tools
      end

    # Mode tier: image/video generation tools stay loaded inside their mode.
    tools =
      case mode do
        :image_generation -> Enum.uniq(tools ++ [GenerateImage])
        :video_generation -> Enum.uniq(tools ++ [GenerateVideo])
        _ -> tools
      end

    # Tier: agent attachments (only when at least one :search-mode attachment exists)
    tools =
      if has_search_attachments?(agent_config) do
        Enum.uniq(tools ++ [SearchAttachedDocs])
      else
        tools
      end

    # Tier 3: Task conversation tools (structural)
    tools = tools ++ task_conversation_tools(conversation)

    # Tier 4: Skill-gated tools (from conversation.skill_tools)
    skill_tools = resolve_skill_tools(conversation.skill_tools)
    tools = Enum.uniq(tools ++ skill_tools)

    # Tier: dynamically loaded tools discovered via tool_search and persisted on
    # the conversation. Re-resolved every turn so they survive hibernation.
    #
    # Actor-scoped (Phase 3): the ACTING user (the message author, threaded in via
    # `opts[:acting_user_id]`) is the MCP actor, falling back to the conversation
    # owner when absent (solo conversations, autonomy runs). MCP tools are gated by
    # that actor through Catalog.resolve/2, so a server the actor lost access to
    # silently drops out next turn (no LLM-visible error). The resolve is a pure
    # cache read over the actor's accessible servers' `cached_tools` (no network),
    # so loaded MCP tools survive hibernation. Passing only `user_id` makes
    # ActorContext.from/1 load the actor from id (the author may differ from
    # `conversation.user`); it still guarantees a concrete `%User{}` or nil.
    #
    # MCP-only: this acting-user scoping affects ONLY the MCP actor_context (and
    # thus `mcp_tools`). The base `tool_context` keeps `user_id`/`user` = owner, so
    # all non-MCP tools continue to act as the conversation owner.
    acting_user_id = Keyword.get(opts, :acting_user_id) || conversation.user_id

    actor_context =
      ActorContext.from(%{
        user_id: acting_user_id,
        conversation_id: conversation.id
      })

    {loaded_tool_modules, mcp_tools, _unknown} =
      Catalog.resolve(conversation.loaded_tools || [], actor_context)

    tools = Enum.uniq(tools ++ loaded_tool_modules)

    # Carry the MCP `%ReqLLM.Tool{}` structs out of the builder via the base tool
    # context under `:__mcp_tools__`, plus the resolved `acting_user_id` so the
    # runner can scope MCP dispatch to the same actor. Because every per-tool
    # context derives from this map, both are identical across tools and survive
    # Preflight's `shared_tool_context/1` intersection into `base_tool_context` ->
    # `effective_tool_context` -> the runner's `context`.
    tool_context =
      tool_context
      |> Map.put(:__mcp_tools__, mcp_tools)
      |> Map.put(:acting_user_id, acting_user_id)

    # Tier 5: Integration tools (agent-scoped)
    agent_id =
      if is_map(agent_config) && !match?(%Ash.NotLoaded{}, agent_config),
        do: agent_config.id,
        else: nil

    integration_tools = get_integration_tools(agent_id)
    tools = tools ++ integration_tools

    # Tier 6: Pre-loaded skills from custom agent
    agent_skill_tools = resolve_agent_pre_loaded_skills(agent_config)
    tools = Enum.uniq(tools ++ agent_skill_tools)

    # Agent-level filtering: remove tools from disabled categories
    tools = filter_by_agent_categories(tools, agent_config)

    # Tier 7: Brain tools (when brain is active, agent has BrainAccess, or user has a brain)
    user_id = Map.get(tool_context, :user_id)

    brain_tools =
      if brain_id || has_agent_brain_access?(agent_id) || user_has_brain?(user_id) do
        [ReadBrain, EditBrain]
      else
        []
      end

    tools = Enum.uniq(tools ++ brain_tools)

    # Super Brain kill switch: don't offer the super_brain tools when the
    # feature is disabled (they would only no-op / search an empty index).
    tools =
      if Magus.SuperBrain.enabled?(),
        do: tools,
        else: tools -- [SuperBrainSearch, PinFact]

    # Capability gating: drop web tools whose provider isn't configured, so a
    # self-host instance without a search/crawl key doesn't offer a dead tool.
    tools =
      if Magus.Capabilities.Search.configured?(),
        do: tools,
        else: tools -- [WebSearch]

    tools =
      if Magus.Capabilities.Crawl.configured?(),
        do: tools,
        else: tools -- [WebFetch]

    # Sandbox capability gating: drop every sandbox tool when no sandbox
    # provider is configured, so a self-host instance without a Daytona/Sprites
    # key doesn't offer dead code-execution tools.
    tools =
      if Magus.Sandbox.Provider.configured?(),
        do: tools,
        else: tools -- @sandbox_tools

    # Resolve parent model key for SpawnSubAgent
    parent_model_key = resolve_parent_model_key(conversation)

    # Build contexts dynamically for whatever tools are in the list
    tool_contexts = build_all_tool_contexts(tool_context, parent_model_key, tools)

    {tools, tool_contexts}
  end

  @doc """
  Builds a tool context map from user/conversation metadata and optional overrides.

  This is a simplified context builder for use outside the full `build_tools/4` pipeline,
  e.g. when constructing context for a skill-based agent that doesn't need the full
  conversation object.
  """
  def build_tool_context(user_id, conversation_id, opts \\ %{}) do
    default_flags = default_isolation_flags()

    Map.merge(default_flags, %{
      user_id: user_id,
      conversation_id: conversation_id,
      __conversation_id__: conversation_id
    })
    |> Map.merge(opts)
  end

  @doc """
  Converts Jido action modules to ReqLLM tool format.
  """
  def build_reqllm_tools(action_modules, tool_contexts) do
    GenerateText.build_tools_from_actions(action_modules, tool_contexts)
  end

  @doc """
  Extracts isolation flags from a custom agent configuration.

  Returns a map with:
  - `:can_read_global_memories` - whether the agent can read global memories
  - `:can_write_global_memories` - whether the agent can write global memories
  - `:can_access_global_files` - whether the agent can access global files

  Defaults to all-true when agent is nil or not loaded.
  """
  def extract_agent_isolation_flags(nil), do: default_isolation_flags()
  def extract_agent_isolation_flags(%Ash.NotLoaded{}), do: default_isolation_flags()

  def extract_agent_isolation_flags(%{
        can_read_global_memories: read,
        can_write_global_memories: write,
        can_access_global_files: files,
        can_access_knowledge: knowledge
      }) do
    %{
      can_read_global_memories: read,
      can_write_global_memories: write,
      can_access_global_files: files,
      can_access_knowledge: knowledge
    }
  end

  def extract_agent_isolation_flags(_), do: default_isolation_flags()

  @doc """
  Resolves skill-declared tool name strings to their action modules.

  Uses the `@skill_tool_mapping` to look up each name. Unknown names are
  logged as warnings and skipped.
  """
  def resolve_skill_tools(nil), do: []
  def resolve_skill_tools([]), do: []

  def resolve_skill_tools(tools) when is_list(tools) do
    Enum.flat_map(tools, fn name ->
      case Map.get(@skill_tool_mapping, name) do
        nil ->
          Logger.warning("Unknown skill tool: #{inspect(name)}")
          []

        mod ->
          [mod]
      end
    end)
  end

  @doc """
  Filters tools by agent's `disabled_tool_categories`.

  Tools not in `@tool_to_category` are always kept (uncategorized).
  Returns all tools when agent is nil or has no disabled categories.
  """
  def filter_by_agent_categories(tools, nil), do: tools
  def filter_by_agent_categories(tools, %Ash.NotLoaded{}), do: tools

  def filter_by_agent_categories(tools, agent) do
    case agent.disabled_tool_categories do
      categories when is_list(categories) and categories != [] ->
        disabled = MapSet.new(categories)

        Enum.filter(tools, fn tool ->
          case Map.get(@tool_to_category, tool) do
            nil -> true
            category -> not MapSet.member?(disabled, category)
          end
        end)

      _ ->
        tools
    end
  end

  @doc """
  Gets tools from enabled integrations for an agent.
  """
  def get_integration_tools(nil), do: []

  def get_integration_tools(custom_agent_id) do
    static_tools =
      case Magus.Integrations.get_enabled_tools_for_agent(custom_agent_id, authorize?: false) do
        {:ok, tools} -> tools
        {:error, _} -> []
      end

    # Include HttpRequest when agent has any custom_api integrations.
    # ConfigureApiIntegration is skill-gated only (via @skill_tool_mapping).
    custom_api_tools =
      case Magus.Integrations.list_by_agent_and_provider(custom_agent_id, :custom_api,
             authorize?: false
           ) do
        {:ok, integrations} when integrations != [] -> [HttpRequest]
        _ -> []
      end

    static_tools ++ custom_api_tools
  end

  # ---------------------------------------------------------------------------
  # Private Functions
  # ---------------------------------------------------------------------------

  defp default_isolation_flags do
    %{
      can_read_global_memories: true,
      can_write_global_memories: true,
      can_access_global_files: true,
      can_access_knowledge: true
    }
  end

  defp task_conversation_tools(conversation) do
    if conversation.is_task_conversation, do: [ReportToParent, CompleteTask], else: []
  end

  # Resolve pre-loaded skills from a custom agent into tool modules.
  # Looks up each skill name in the Registry, collects their declared tools,
  # and resolves those tool name strings to modules via @skill_tool_mapping.
  defp resolve_agent_pre_loaded_skills(nil), do: []
  defp resolve_agent_pre_loaded_skills(%Ash.NotLoaded{}), do: []

  defp resolve_agent_pre_loaded_skills(agent) do
    case agent.pre_loaded_skills do
      skills when is_list(skills) and skills != [] ->
        alias Magus.Agents.Skills.Registry

        Enum.flat_map(skills, fn skill_name ->
          case Registry.get_skill(skill_name) do
            {:ok, skill} -> resolve_skill_tools(skill.tools)
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp build_all_tool_contexts(tool_context, parent_model_key, tools) do
    # Tools with custom contexts
    custom = %{
      SpawnSubAgent => Map.merge(tool_context, %{__parent_model_key__: parent_model_key})
    }

    # All other tools get the standard tool_context
    Enum.reduce(tools, custom, fn tool, acc ->
      Map.put_new(acc, tool, tool_context)
    end)
  end

  defp resolve_parent_model_key(conversation) do
    cond do
      loaded?(conversation, :custom_agent) and loaded?(conversation.custom_agent, :model) ->
        conversation.custom_agent.model.key

      loaded?(conversation, :selected_model) ->
        conversation.selected_model.key

      loaded?(conversation, :user) and loaded?(conversation.user, :selected_model) ->
        conversation.user.selected_model.key

      true ->
        nil
    end
  end

  defp loaded?(nil, _field), do: false
  defp loaded?(%Ash.NotLoaded{}, _field), do: false

  defp loaded?(record, field) do
    value = Map.get(record, field)
    not is_nil(value) and not match?(%Ash.NotLoaded{}, value)
  end

  defp has_agent_brain_access?(nil), do: false

  defp has_agent_brain_access?(agent_id) do
    require Ash.Query

    Magus.Workspaces.ResourceAccess
    |> Ash.Query.filter(
      resource_type == :brain and grantee_type == :custom_agent and grantee_id == ^agent_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> then(&(&1 != []))
  end

  defp user_has_brain?(nil), do: false

  defp user_has_brain?(user_id) do
    require Ash.Query

    Magus.Brain.BrainResource
    |> Ash.Query.filter(user_id == ^user_id and is_archived == false)
    |> Ash.Query.limit(1)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, [_ | _]} -> true
      _ -> false
    end
  end

  defp has_search_attachments?(nil), do: false
  defp has_search_attachments?(%Ash.NotLoaded{}), do: false

  defp has_search_attachments?(agent) when is_map(agent) do
    require Ash.Query

    case Map.get(agent, :id) do
      nil ->
        false

      agent_id ->
        Magus.Agents.CustomAgentAttachment
        |> Ash.Query.filter(custom_agent_id == ^agent_id and mode == :search)
        |> Ash.Query.limit(1)
        |> Ash.read_one!(authorize?: false)
        |> case do
          nil -> false
          _ -> true
        end
    end
  end

  defp has_search_attachments?(_), do: false
end
