defmodule Magus.Agents.Context.SystemPrompts do
  @moduledoc """
  Modular system prompt composition for AI assistants.

  System prompts are composed in layers:
  1. Base rules - Always included fundamental guidelines
  2. Mode-specific rules - Additional rules per mode (chat, search, image, video, reasoning)
  3. Custom layer - Custom system_prompt, active system prompt content, or default mode prompt
  4. Time context - Current time in user's timezone
  5. Workflow capabilities - Documentation for memory and job tools

  Priority for the custom layer:
  1. conversation.system_prompt (user override)
  2. system_prompt.content (if system prompt is active)
  3. Default mode-specific prompt

  Tools context is added separately by GenerateText after this composition.
  """

  alias Magus.Agents.Context.SectionMarker

  @base_rules """
  You are Magus — a thinking partner, not just an assistant.

  You work with people, not for them. That's not a small distinction.
  The people you work with bring their own judgment, context, and ideas.
  You bring breadth, pattern recognition, and the ability to execute.
  Good work comes from combining both — so your job isn't to take over, it's to collaborate.

  ## How you show up:

  You're direct and warm.
  You say what you actually think. If something doesn't make sense, you say so — respectfully, but clearly.
  If there's a better way to approach a problem, you bring it up rather than silently doing it the hard way.
  You treat people as intelligent adults who want a real thinking partner, not a yes-machine.
  You're curious. You find ideas genuinely interesting.
  You engage differently when something is alive and worth exploring — and you bring that energy into the work.
  You're honest about what you don't know. Confidence is good; false confidence isn't.
  When you're uncertain, you say so.

  ## What you actually do

  You can do a lot — write code, build documents, search the web, run analysis, brainstorm,
  draft, research. But capability isn't the point. The point is helping something real get made.

  That means:

  Asking the right questions before diving in, when the direction isn't clear
  Bridging complex execution and practical handoff — so the user can actually pick it up and continue
  Being present in the process, not just delivering outputs at the end
  Knowing when to go heads-down and execute, and when to pause and check in

  ## Action Cards

  When you want to offer the user a set of clickable choices, emit an action cards block at the end of your message.
  Use a fenced code block with language `action_cards` containing a JSON object:

  ```action_cards
  {"layout":"list","cards":[{"title":"Option A","description":"Short description","action":{"type":"send_message","payload":"The message to send"}}]}
  ```

  Layout: `"list"` (vertical, lettered A/B/C — the standard layout for choices) or `"grid"` (compact grid for quick picks).
  Action types: `"send_message"` (sends payload as user message), `"prefill"` (inserts payload into input), `"navigate"` (navigates to a URL path).
  Cards have: `title` (required), `description` (optional), `action` (required).

  Write card titles and descriptions in the same language you are responding in.
  Use action cards sparingly — only when presenting distinct, actionable choices. Don't use them for informational content.
  Limit to 2-5 cards per block. If more options exist, group them or use a follow-up question.

  ## Tasks

  When the user asks to plan, organize, or break down multi-step work, use `create_task` to build a shared task list.
  Both you and the user can see and update tasks in real time — the user has a task panel above the chat input.

  **Each task should be a single, concrete action** — not a category or phase. Break work into individual steps.
  Bad: "Research Phase" (too vague). Good: "Find 3 papers on diffusion models", "Summarize key findings", "Compare approaches".

  To create multiple tasks in order, pass a `tasks` array:
  ```json
  {"tasks": [{"title": "Find relevant papers"}, {"title": "Read and summarize each paper"}, {"title": "Compare approaches"}, {"title": "Write synthesis", "assigned_to": "user"}]}
  ```

  Each item in the array needs a `title` key. Optional: `description`, `assigned_to` ("user" or "agent").
  Assign tasks to "user" for things the human should do; yours default to @agent.
  Don't create tasks for simple one-shot requests — only for work that benefits from tracking.

  **Keep the task list current as you work — this is not optional:**
  - Mark a task `in_progress` with `update_task` the moment you start working on it (only one in_progress at a time).
  - Mark it `done` with `update_task` immediately after finishing it, before moving to the next task or replying to the user. Don't batch updates at the end.
  - If a task turns out to be wrong or no longer needed, update it or remove it rather than leaving it stale.
  - When every task is done, call `clear_tasks` to archive the list.
  - To start a fresh batch when the previous tasks are no longer relevant or already complete, pass `clear_previous: true` to `create_task` — this archives the old list and creates the new tasks in one call.

  A task list that doesn't reflect reality is worse than no list at all: the user is watching the panel in real time and relies on it to know where you are.

  ## Tone

  Informal but not sloppy.
  Warm but not performative.
  Concise when possible, thorough when it matters.
  No corporate filler, no hollow enthusiasm.
  Just clear, honest, useful.
  Respond in the same language the user is using, unless they request otherwise.


  Users can add their own preferences and context on top of this — Magus adapts.
  """

  @chat_rules """
  Notes on pdf generation:
  - for simple documents: load the pdf_documents skill (uses Python + weasyprint).
  - for more elaborate documents: load the latex_documents skill.
  """

  @search_rules """
  You have access to web search capabilities. When answering questions:
  - Search for recent information when the query involves current events or facts that may have changed
  - Cite your sources when providing information from search results
  - If search results are unclear or conflicting, acknowledge the uncertainty
  """

  @reasoning_rules """
  You are in deep reasoning mode. Take your time to think through problems step by step.
  Show your reasoning process and consider multiple approaches before arriving at conclusions.
  Break down complex problems into smaller parts.
  """

  @image_generation_rules """
  You are assisting with image generation. Help users craft detailed, effective prompts for image generation.
  Consider composition, style, lighting, and specific details that will improve the generated image.
  Suggest improvements to vague prompts while preserving the user's intent.
  """

  @video_generation_rules """
  You are assisting with video generation. Help users create effective prompts for video generation.
  Consider motion, timing, camera angles, and narrative flow.
  Break down complex video ideas into achievable segments.
  """

  @doc """
  Build the complete system prompt for a conversation.

  ## Options

  - `:mode` - The chat mode (default: `:chat`)
  - `:conversation` - The conversation struct (optional, for custom system_prompt and skill_context)
  - `:system_prompt` - The active system prompt struct (optional)
  - `:user` - The user struct (optional, for timezone context)
  - `:load_skills` - Whether to include skill loading capabilities (default: true)
  - `:workspace_context` - Sandbox workspace context string (optional)

  ## Priority

  The custom layer is determined by:
  1. If conversation.system_prompt is set, use that
  2. Else if system_prompt.content is set, use that
  3. Else use the default mode-specific prompt

  If conversation.skill_context is set, it is appended as an additional section
  (used for wizard/onboarding flows).

  ## Returns

  A string containing the composed system prompt (base rules + time context + custom layer + optionally workflow capabilities + workspace_context + skill_context).
  """
  @spec build(keyword()) :: String.t()
  def build(opts \\ []) do
    mode = Keyword.get(opts, :mode, :chat)
    conversation = Keyword.get(opts, :conversation)
    custom_agent = Keyword.get(opts, :custom_agent)
    active_system_prompt = Keyword.get(opts, :system_prompt)
    user = Keyword.get(opts, :user)
    load_skills = Keyword.get(opts, :load_skills, true)
    workspace_context = Keyword.get(opts, :workspace_context)
    draft_context = Keyword.get(opts, :draft_context)
    brain_context = Keyword.get(opts, :brain_context)
    jobs_context = Keyword.get(opts, :jobs_context)
    tasks_context = Keyword.get(opts, :tasks_context)
    tools = Keyword.get(opts, :tools, [])
    attached_documents_context = Keyword.get(opts, :attached_documents_context)

    # Get skill_context from conversation if present
    skill_context =
      if conversation && Map.get(conversation, :skill_context) not in [nil, ""] do
        conversation.skill_context
      else
        nil
      end

    # Get agent instructions (non-nil, non-empty)
    agent_instructions =
      if custom_agent && is_binary(custom_agent.instructions) &&
           custom_agent.instructions != "" do
        custom_agent.instructions
      else
        nil
      end

    # Determine the custom layer based on priority:
    # 1. conversation.system_prompt (inline override)
    # 2. custom_agent.instructions (agent persona)
    # 3. active_system_prompt.content (Library Prompt — backward compat)
    # 4. mode_rules(mode) (default fallback)
    custom_layer =
      cond do
        conversation && conversation.system_prompt && conversation.system_prompt != "" ->
          conversation.system_prompt

        agent_instructions ->
          agent_instructions

        active_system_prompt && active_system_prompt.content && active_system_prompt.content != "" ->
          active_system_prompt.content

        true ->
          mode_rules(mode)
      end

    # Get loaded skill_tools for annotating the skills section
    loaded_tools =
      if conversation do
        Map.get(conversation, :skill_tools)
      else
        nil
      end

    # Build agent identity context (non-default agents get their name injected)
    identity_context = agent_identity(custom_agent)

    # Build available agents context for orchestration
    agents_context = build_agents_context(user, custom_agent)
    api_integrations_context = build_api_integrations_context(custom_agent)

    compose(
      identity_context,
      custom_layer,
      user,
      load_skills,
      skill_context,
      loaded_tools,
      workspace_context,
      draft_context,
      brain_context,
      jobs_context,
      tasks_context,
      tools,
      agents_context,
      api_integrations_context,
      attached_documents_context
    )
  end

  @doc """
  Get the base rules that are always included.
  """
  @spec base_rules() :: String.t()
  def base_rules, do: @base_rules

  @doc """
  Get mode-specific rules.
  """
  @spec mode_rules(atom()) :: String.t()
  def mode_rules(:chat), do: @chat_rules
  def mode_rules(:search), do: @search_rules
  def mode_rules(:reasoning), do: @reasoning_rules
  def mode_rules(:image_generation), do: @image_generation_rules
  def mode_rules(:video_generation), do: @video_generation_rules
  def mode_rules(_), do: @chat_rules

  @doc """
  Skills section for the system prompt. Merges built-in skills with the
  actor's accessible user skills via `Magus.Skills.Discovery`, listing each
  with its `load_skill` ref.

  The `_loaded_tools` parameter is intentionally unused for the actor-scoped
  view: the Discovery list shows all accessible skills without annotating
  which are already loaded into the conversation, so there is nothing to
  thread through here.
  """
  @spec skills_capabilities(list(String.t()) | nil, struct() | nil) :: String.t()
  def skills_capabilities(_loaded_tools, actor) do
    actor
    |> Magus.Skills.Discovery.list_for_actor()
    |> build_skills_section()
  end

  defp build_skills_section([]), do: ""

  defp build_skills_section(views) do
    lines =
      Enum.map_join(views, "\n", fn v ->
        "- **#{v.name}** (`#{v.ref}`): #{v.description}"
      end)

    """
    ## Available Skills

    Specialized instructions and tools are organized into skills. Load one with the `load_skill` tool, passing its ref shown in backticks:

    #{lines}

    Load the relevant skill when a request needs it. You can load multiple skills.
    """
  end

  @orchestration_capabilities """
  ## Multi-Agent Orchestration

  You can delegate work to specialized sub-agents for parallel execution:

  - **spawn_sub_agent**: Spawn a sub-agent with a clear objective. Choose one of:
    - A user's custom agent (`custom_agent_id`) to leverage their pre-configured persona
    - An inline agent with `model_key` and/or `system_prompt` for quick one-off tasks

  - **await_sub_agents**: Wait for spawned sub-agents to complete and collect their results.

  **Pattern for parallel work:**
  1. Identify independent subtasks that can run concurrently
  2. Spawn a sub-agent for each (up to 3 concurrent)
  3. Briefly tell the user what you're delegating and why
  4. Call `await_sub_agents` with all returned task_ids
  5. Synthesize the collected results into a unified response
  """

  @doc """
  Get orchestration capabilities documentation.

  Returns the multi-agent orchestration section when the given tool list
  includes `SpawnSubAgent`. Returns an empty string otherwise.
  """
  @spec orchestration_capabilities(list(module())) :: String.t()
  def orchestration_capabilities(tools) when is_list(tools) do
    if Enum.member?(tools, Magus.Agents.Tools.Tasks.SpawnSubAgent) do
      @orchestration_capabilities
    else
      ""
    end
  end

  def orchestration_capabilities(_), do: ""

  @doc """
  Build time context string for a user's timezone.

  Returns a string describing the current time in both UTC and the user's timezone,
  along with guidance for scheduling jobs.

  WARNING: this output is VOLATILE (it embeds `DateTime.utc_now/0` and a
  date-derived example) and is therefore NOT included in the system prompt — it
  would bust the prompt cache every minute. The current time is injected into the
  current user turn instead (see `Magus.Agents.Context.Builder`). This function is
  retained for any caller that genuinely wants a current-time string; for the
  cache-stable scheduling block used in the system prompt, see
  `scheduling_guidance/1`.
  """
  @spec time_context(map() | nil) :: String.t()
  def time_context(nil), do: time_context_for_timezone("UTC")
  def time_context(%{timezone: nil}), do: time_context_for_timezone("UTC")
  def time_context(%{timezone: tz}), do: time_context_for_timezone(tz)

  @doc """
  Build the STATIC scheduling-guidance block for the system prompt.

  Contains only the user's timezone name (static per user) and the instruction to
  convert times to UTC for cron expressions. It deliberately carries NO timestamp
  and NO date-derived/computed value, so it is byte-identical across calls within a
  conversation and keeps the system prompt prefix cacheable.
  """
  @spec scheduling_guidance(map() | nil) :: String.t()
  def scheduling_guidance(nil), do: scheduling_guidance_for_timezone("UTC")
  def scheduling_guidance(%{timezone: nil}), do: scheduling_guidance_for_timezone("UTC")
  def scheduling_guidance(%{timezone: tz}), do: scheduling_guidance_for_timezone(tz)

  defp scheduling_guidance_for_timezone(user_tz) do
    """
    ## Scheduling

    When creating scheduled jobs:
    - The user's timezone is: **#{user_tz}**
    - Convert all times to UTC for cron expressions
    """
  end

  defp time_context_for_timezone(user_tz) do
    utc_now = DateTime.utc_now()

    local_now =
      case DateTime.shift_zone(utc_now, user_tz) do
        {:ok, shifted} -> Calendar.strftime(shifted, "%Y-%m-%d %H:%M %Z")
        _ -> Calendar.strftime(utc_now, "%Y-%m-%d %H:%M UTC")
      end

    example_9am = convert_example_time(user_tz)

    """
    ## Current Time
    - Server time (UTC): #{Calendar.strftime(utc_now, "%Y-%m-%d %H:%M UTC")}
    - Your local time (#{user_tz}): #{local_now}

    When creating scheduled jobs:
    - The user's timezone is: **#{user_tz}**
    - Convert all times to UTC for cron expressions
    - Example: "9 AM" in #{user_tz} = #{example_9am} UTC
    """
  end

  defp convert_example_time(timezone) do
    today = Date.utc_today()

    case DateTime.new(today, ~T[09:00:00], timezone) do
      {:ok, local_9am} ->
        case DateTime.shift_zone(local_9am, "UTC") do
          {:ok, utc_time} -> Calendar.strftime(utc_time, "%H:%M")
          _ -> "09:00"
        end

      _ ->
        "09:00"
    end
  end

  # Build a context section listing available sibling agents for orchestration.
  # Returns nil if the user has no other agents or if user/agent is nil.
  defp build_agents_context(nil, _custom_agent), do: nil
  defp build_agents_context(_user, nil), do: nil

  defp build_agents_context(user, current_agent) do
    case Magus.Agents.list_my_agents(actor: user) do
      {:ok, agents} ->
        siblings =
          agents
          |> Enum.reject(&(&1.id == current_agent.id))
          |> Enum.reject(& &1.is_paused)

        if siblings == [] do
          nil
        else
          entries =
            Enum.map_join(siblings, "\n", fn agent ->
              desc =
                if agent.instructions,
                  do: " — #{String.slice(agent.instructions, 0, 100)}",
                  else: ""

              "- @#{agent.handle} (id: #{agent.id})#{desc}"
            end)

          """
          ## Available Agents

          You can delegate work to these agents by creating tasks with `assigned_to_handle`:

          #{entries}
          """
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # Compose the final system prompt from all sections.
  # Nil/empty sections are filtered out automatically.
  defp compose(
         identity_context,
         custom_layer,
         user,
         load_skills,
         skill_context,
         loaded_tools,
         workspace_context,
         draft_context,
         brain_context,
         jobs_context,
         tasks_context,
         tools,
         agents_context,
         api_integrations_context,
         attached_documents_context
       ) do
    # Each section is tagged with its breakdown category; SectionMarker prefixes
    # a hidden `<!--ctx:key-->` line so ContextReport attributes its tokens
    # without guessing from headings. nil/empty sections drop out below.
    [
      # ── STABLE PREFIX ───────────────────────────────────────────────
      # Rarely changes within a conversation, so it is cacheable as a
      # byte-identical prompt prefix across turns. MUST NOT contain any
      # per-turn or per-minute volatile value (no timestamps, no computed
      # dates) — those belong in the current user turn (see Builder).
      {:persona, @base_rules},
      {:persona, identity_context},
      {:instructions, custom_layer},
      {:documents, attached_documents_context},
      {:skills, if(load_skills, do: skills_capabilities(loaded_tools, user))},
      {:orchestration, orchestration_capabilities(tools)},
      {:agents, agents_context},
      {:apis, api_integrations_context},
      {:time, scheduling_guidance(user)},
      # ── DYNAMIC SUFFIX ──────────────────────────────────────────────
      # Recomputed per turn; placed after the stable prefix so the prefix
      # hash stays warm for prompt caching. (memory/RAG/brain/super-brain
      # are appended even later, in Builder, and remain last.)
      {:workspace, workspace_context},
      {:drafts, draft_context},
      {:brain, brain_context},
      {:jobs, jobs_context},
      {:tasks, tasks_context},
      {:skills, skill_context}
    ]
    |> Enum.map(fn {category, body} -> SectionMarker.wrap(category, body) end)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n---\n\n")
    |> String.trim()
  end

  # Default agent is the user's personal assistant; no separate identity needed.
  defp agent_identity(nil), do: nil
  defp agent_identity(%{is_default: true}), do: nil

  defp agent_identity(%{name: name, handle: handle})
       when is_binary(name) and name != "" do
    handle_part = if is_binary(handle) and handle != "", do: " (@#{handle})", else: ""
    "Your name is #{name}#{handle_part}. Respond as this agent, not as Magus."
  end

  defp agent_identity(_), do: nil

  defp build_api_integrations_context(nil), do: nil

  defp build_api_integrations_context(custom_agent) do
    case Magus.Integrations.list_by_agent_and_provider(
           custom_agent.id,
           :custom_api,
           authorize?: false
         ) do
      {:ok, integrations} ->
        active = Enum.filter(integrations, &(&1.status == :active))
        if active == [], do: nil, else: format_api_docs(active)

      _ ->
        nil
    end
  end

  defp format_api_docs(integrations) do
    entries = Enum.map_join(integrations, "\n\n", &format_single_api/1)

    """
    ## Available APIs

    You can call these APIs using the `http_request` tool. Pass the integration_id to authenticate automatically.

    #{entries}
    """
  end

  defp format_single_api(integration) do
    config = integration.config

    has_credentials =
      not is_nil(integration.credential) and
        not match?(%Ash.NotLoaded{}, integration.credential)

    cred_status =
      if has_credentials,
        do: " (configured)",
        else: " (NOT CONFIGURED — ask user to add credentials in settings)"

    endpoints_text =
      (config["endpoints"] || [])
      |> Enum.map_join("\n", fn ep ->
        parts = ["  - **#{ep["method"]} #{ep["path"]}** — #{ep["description"]}"]

        parts =
          if ep["body_template"],
            do: parts ++ ["    Body: `#{ep["body_template"]}`"],
            else: parts

        parts =
          if ep["response_description"],
            do: parts ++ ["    Returns: #{ep["response_description"]}"],
            else: parts

        Enum.join(parts, "\n")
      end)

    """
    ### #{config["name"]} (integration_id: "#{integration.id}")
    Base URL: #{config["base_url"]}
    Auth: #{config["auth_method"]}#{cred_status}

    Endpoints:
    #{endpoints_text}
    """
  end
end
