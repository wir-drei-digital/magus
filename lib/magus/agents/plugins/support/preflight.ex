defmodule Magus.Agents.Plugins.Support.Preflight do
  @moduledoc false
  # Pre-flight validation: model resolution, usage limit checks, and signal
  # transformation before handing off to ReAct or media generation.

  require Logger

  alias Magus.Agents.Context.Builder
  alias Magus.Agents.Routing.AutoRouteResolver
  alias Magus.Agents.Tools.ToolBuilder
  alias Magus.Agents.Plugins.Support.{ErrorMessages, Helpers}
  alias Magus.Models.{Resolution, Resolver}
  alias Magus.Agents.Signals
  alias Magus.Agents.SlashCommands

  @doc """
  Validate usage limits and build the `ai.react.query` signal for ReAct.

  Returns `{:ok, {:continue, react_signal}}` on success, or halts with an
  override on limit errors.
  """
  def build_react_signal(signal, agent, mode) do
    data = signal.data || %{}
    state = agent.state || %{}
    conversation_id = Helpers.get_conversation_id(agent)

    raw_model_keys =
      Helpers.normalize_model_keys(data[:model_keys] || data["model_keys"] || state[:model_keys])

    selected_model_id = data[:selected_model_id] || data["selected_model_id"]
    message_id = data[:message_id] || data["message_id"]
    raw_text = data[:text] || data["text"] || ""

    # Load the conversation once (with workspace preloaded) and reuse it for
    # workspace-model checks, model resolution, and build_request_context.
    conversation =
      case load_conversation_context(conversation_id, conversation_context_from_data(data)) do
        {:ok, loaded} -> loaded
        _ -> nil
      end

    agent_slash_commands = get_agent_slash_commands(conversation)

    # The member who sent the triggering message (owner fallback for autonomous
    # turns) is the actor for BOTH slash-skill visibility below AND, further down,
    # the credential actor for model resolution + the spend-gate subject (magus-k3at).
    # Compute once and reuse. In a shared conversation a non-owner member must
    # resolve their OWN personal skills, so slash resolution uses this member, not
    # the conversation owner.
    acting_user_id = Helpers.acting_user_id(agent, message_id)
    actor = load_actor(acting_user_id, conversation)

    text =
      case SlashCommands.resolve(raw_text, agent_slash_commands,
             actor: actor,
             conversation: conversation
           ) do
        {{:command, instruction}, remaining} ->
          instruction <> "\n" <> remaining

        {{:skill, ref}, remaining} ->
          load_slash_skill(ref, conversation_id, actor)
          remaining

        {:none, remaining} ->
          remaining
      end

    # Resolve :auto via AutoRouter when no explicit model is set.
    route_metadata = build_route_metadata(data)

    model_keys =
      maybe_auto_route(
        raw_model_keys,
        text,
        data[:mode] || data["mode"] || mode,
        conversation,
        route_metadata
      )

    # The dispatcher resolves chat :auto upstream and threads the routing
    # reason into the signal (see Magus.Agents.Dispatcher.build_signal_data:
    # routing_reason). A present routing_reason, or a raw chat key still :auto
    # (Preflight's own secondary maybe_auto_route path), means the chat key was
    # auto-routed rather than explicitly picked.
    routing_reason = data[:routing_reason] || data["routing_reason"]

    auto_routed = %{
      chat: routing_reason not in [nil, ""] or raw_model_keys[:chat] == :auto,
      image: raw_model_keys[:image] == :auto,
      video: raw_model_keys[:video] == :auto
    }

    # `acting_user_id` (the triggering member, owner fallback) is computed above
    # for slash-skill visibility and reused here as the credential actor for model
    # resolution (scopes owned-model visibility) and the spend-gate subject
    # (magus-k3at).
    {:ok, resolution} =
      Resolver.resolve(acting_user_id, %{
        model_keys: model_keys,
        mode: mode,
        selected_model_id: selected_model_id,
        preloaded: preloaded_model_candidates(conversation),
        auto_routed: auto_routed
      })

    model = resolution.model

    # Hard-stop (phase 2b-2b): a broken EXPLICIT selection (one that resolved to
    # something other than what was asked) blocks the turn before any LLM call,
    # on the same error/event rails as the region/limit blocks below. :auto and
    # unselected paths carry no requested_selection and never degrade, so they
    # are behavior-neutral here.
    if Resolution.degraded?(resolution) do
      handle_broken_selection(
        conversation_id,
        message_id,
        resolution,
        broken_selection_scope(resolution, conversation, mode)
      )

      {:ok, {:override, Jido.Actions.Control.Noop}}
    else
      # Enforce the spend gate against the member who sent the triggering message,
      # not the conversation owner (magus-k3at); owner fallback for autonomous turns.
      user = load_user_for_limits(acting_user_id)
      workspace = resolve_workspace(conversation, conversation_id)

      build_react_signal_after_gates(
        user,
        mode,
        model,
        workspace,
        conversation_id,
        message_id,
        state,
        data,
        conversation,
        model_keys,
        text
      )
    end
  end

  defp build_react_signal_after_gates(
         user,
         mode,
         model,
         workspace,
         conversation_id,
         message_id,
         state,
         data,
         conversation,
         model_keys,
         text
       ) do
    case check_usage_limit(user, mode, model, workspace) do
      {:ok, :allowed} ->
        # Check region availability: block if model not in user's allowed regions
        unless Magus.Providers.Routing.model_available_for_user?(model, user) do
          handle_region_unavailable(conversation_id, message_id)
          {:ok, {:override, Jido.Actions.Control.Noop}}
        else
          provider_routing = Magus.Providers.Routing.build_provider_routing(model, user)

          request_context =
            build_request_context(conversation_id, state, data, mode, model, conversation)

          # Merge provider routing into llm_opts
          llm_opts_with_routing =
            merge_provider_routing(request_context.llm_opts, provider_routing)

          resolved_model_key = model.key || model_key_for_mode(model_keys, mode)

          react_signal =
            %{
              query: text,
              request_id: message_id
            }
            |> maybe_put_field(:model, resolved_model_key)
            |> maybe_put_field(:model_name, model.name)
            |> maybe_put_field(:system_prompt, request_context.system_prompt)
            |> maybe_put_field(:tool_context, request_context.tool_context)
            |> maybe_put_field(:tools, request_context.tools)
            |> maybe_put_field(:max_iterations, request_context.max_iterations)
            |> maybe_put_field(:llm_opts, llm_opts_with_routing)
            |> maybe_put_field(:initial_messages, request_context.initial_messages)
            |> maybe_put_runtime_field(:model, data)
            |> maybe_put_runtime_field(:tool_context, data)
            |> maybe_put_runtime_field(:tools, data)
            |> maybe_put_runtime_field(:max_iterations, data)
            |> maybe_put_runtime_field(:llm_opts, data)
            |> maybe_put_runtime_field(:req_http_options, data)
            |> maybe_put_runtime_field(:system_prompt, data)
            |> maybe_put_runtime_field(:model_name, data)
            |> then(&Jido.Signal.new!("ai.react.query", &1))

          {:ok, {:continue, react_signal}}
        end

      {:error, error} ->
        handle_limit_exceeded(conversation_id, message_id, error)
        {:ok, {:override, Jido.Actions.Control.Noop}}
    end
  end

  @doc """
  Build an `ai.react.query` signal for an `agent.resume` wake-up.

  Skips usage limits, slash command parsing, and persistence — this is a
  synthetic prompt, not a user-originated message. The query text instructs
  the LLM to continue based on the now-completed sub-agent results in its
  conversation history.
  """
  def build_resume_react_signal(signal, agent) do
    state = agent.state || %{}
    conversation_id = Helpers.get_conversation_id(agent)

    data = signal.data || %{}
    count = data[:completed_count] || data["completed_count"] || 0

    query = """
    [System resume] #{count} sub-agent(s) you spawned have completed.
    Their results are attached to the corresponding spawn_sub_agent tool calls
    above in this conversation. Continue your work using those results, or
    respond to the user if the task is now complete.
    """

    conversation =
      case load_conversation_context(conversation_id, %{}) do
        {:ok, loaded} -> loaded
        _ -> nil
      end

    raw_model_keys = Helpers.normalize_model_keys(state[:model_keys])
    mode = state[:mode] || :chat

    # Scope owned-model visibility to the acting user (agent owner for these
    # autonomous resume turns): the caller's acting_user_id if present, else
    # the agent owner from state.
    acting_user_id = data[:acting_user_id] || data["acting_user_id"] || state[:user_id]

    {:ok, resolution} =
      Resolver.resolve(acting_user_id, %{
        model_keys: raw_model_keys,
        mode: mode,
        selected_model_id: nil,
        preloaded: preloaded_model_candidates(conversation)
      })

    model = resolution.model

    if Resolution.degraded?(resolution) do
      # Same hard-stop on the resume path: a broken pinned selection blocks the
      # synthetic continuation before any LLM call. No triggering user message
      # exists here, so the error event is not attached to one.
      handle_broken_selection(
        conversation_id,
        nil,
        resolution,
        broken_selection_scope(resolution, conversation, mode)
      )

      {:ok, {:override, Jido.Actions.Control.Noop}}
    else
      build_resume_react_signal_after_check(
        query,
        conversation_id,
        state,
        mode,
        model,
        conversation,
        raw_model_keys
      )
    end
  end

  defp build_resume_react_signal_after_check(
         query,
         conversation_id,
         state,
         mode,
         model,
         conversation,
         raw_model_keys
       ) do
    # CRITICAL: pass a synthetic message_id in data so build_request_context
    # does not drop initial_messages. The id is a fresh UUID that exists in
    # nobody's DB, so the BuildMessageHistory query's exclude_id filter will
    # not match anything — all conversation history is included.
    request_id = "resume-#{Ash.UUID.generate()}"
    resume_message_id = Ash.UUID.generate()
    context_data = %{message_id: resume_message_id}

    request_context =
      build_request_context(conversation_id, state, context_data, mode, model, conversation)

    resolved_model_key = model.key || model_key_for_mode(raw_model_keys, mode)

    react_signal =
      %{
        query: query,
        request_id: request_id
      }
      |> maybe_put_field(:model, resolved_model_key)
      |> maybe_put_field(:model_name, model.name)
      |> maybe_put_field(:system_prompt, request_context.system_prompt)
      |> maybe_put_field(:tool_context, request_context.tool_context)
      |> maybe_put_field(:tools, request_context.tools)
      |> maybe_put_field(:max_iterations, request_context.max_iterations)
      |> maybe_put_field(:llm_opts, request_context.llm_opts)
      |> maybe_put_field(:initial_messages, request_context.initial_messages)
      |> then(&Jido.Signal.new!("ai.react.query", &1))

    {:ok, {:continue, react_signal}}
  end

  @doc """
  Read-only assembly of the full request context Preflight would inject for a
  conversation, for inspection/debugging (see `mix agent.preflight`).

  Reuses the same `build_request_context/6` the live path uses, so the
  returned `system_prompt` / `initial_messages` / `tools` match what the agent
  would receive. It deliberately skips usage/region checks, auto-routing, and
  every side effect, and never calls the LLM. The production path
  (`build_react_signal/3`) is unaffected.

  Options:

    * `:text` - simulates the next incoming user message, appended after the
      real history (default `""`).
    * `:mode` - overrides the conversation's `chat_mode`.
    * `:model_key` - overrides the resolved chat model (a model key string).

  Returns `{:ok, %{conversation:, mode:, model:, model_keys:, text:,
  request_context:}}` or `{:error, reason}`.
  """
  def assemble_context(conversation_id, opts \\ []) when is_binary(conversation_id) do
    with {:ok, conversation} <- load_conversation_context(conversation_id, nil),
         {:ok, resolved_keys} <- Magus.Agents.Routing.ModelKeyResolver.resolve(conversation) do
      model_keys =
        resolved_keys
        |> Helpers.normalize_model_keys()
        |> maybe_override_chat_model(opts[:model_key])

      mode = opts[:mode] || conversation.chat_mode || :chat
      text = opts[:text] || ""

      # Read-only assembly path: no triggering message in scope, so scope
      # owned-model visibility to the conversation (agent) owner.
      acting_user_id = conversation.user_id

      {:ok, resolution} =
        Resolver.resolve(acting_user_id, %{
          model_keys: model_keys,
          mode: mode,
          selected_model_id: nil,
          preloaded: preloaded_model_candidates(conversation)
        })

      model = resolution.model

      # Synthetic message_id (in nobody's DB) so build_request_context keeps
      # initial_messages: the history query's exclude filter matches nothing,
      # so all real messages are included and `text` is appended as the
      # simulated current turn.
      data = %{text: text, message_id: Ash.UUID.generate()}
      state = %{user_id: conversation.user_id}

      request_context =
        build_request_context(conversation_id, state, data, mode, model, conversation)

      {:ok,
       %{
         conversation: conversation,
         mode: mode,
         model: model,
         model_keys: model_keys,
         text: text,
         request_context: request_context
       }}
    end
  end

  defp maybe_override_chat_model(model_keys, nil), do: model_keys

  defp maybe_override_chat_model(model_keys, key) when is_binary(key),
    do: Map.put(model_keys, :chat, key)

  @doc "Resolve model and check usage limits. Returns `{:ok, model}` or `{:error, error}`."
  def validate_and_resolve_model(model_keys, mode, selected_model_id, user_id) do
    # `data` is not in scope here; the caller's user_id (the limits subject) is
    # the acting user that scopes owned-model visibility.
    {:ok, resolution} =
      Resolver.resolve(user_id, %{
        model_keys: model_keys,
        mode: mode,
        selected_model_id: selected_model_id
      })

    model = resolution.model
    user = load_user_for_limits(user_id)

    case check_usage_limit(user, mode, model, nil) do
      {:ok, :allowed} -> {:ok, model}
      {:error, _} = error -> error
    end
  end

  @doc "Broadcast limit-exceeded error and reset state to idle."
  def handle_limit_exceeded(conversation_id, message_id, error) do
    error_message = ErrorMessages.format_user_friendly_error(:limit_exceeded, error)

    Logger.info("Usage limit exceeded for conversation #{conversation_id}: #{error_message}")

    Signals.error(conversation_id, message_id, :limit_exceeded, error_message)
    Signals.state_change(conversation_id, :idle)
    Signals.response_complete(conversation_id, %{})

    ErrorMessages.create_error_event(conversation_id, :limit_exceeded, error)
  end

  @doc """
  Block a turn whose explicit model selection is broken (degraded).

  Mirrors the region/limit block: broadcasts the ephemeral error signal, resets
  the conversation to idle, and persists a durable `:event` message. The event's
  `tool_call_data` carries the STRING-keyed machine-readable payload the SPA
  consumes verbatim: `kind`, `requested_by`, `requested_value`, `fallback_key`,
  `scope`.
  """
  def handle_broken_selection(conversation_id, message_id, %Resolution{} = resolution, scope) do
    payload = broken_selection_payload(resolution, scope)
    error_message = broken_selection_message()

    Logger.info(
      "Broken model selection for conversation #{conversation_id}: " <>
        "requested_by=#{payload["requested_by"]} scope=#{payload["scope"]}"
    )

    Signals.error(conversation_id, message_id, :broken_model_selection, error_message)
    Signals.state_change(conversation_id, :idle)
    Signals.response_complete(conversation_id, %{})

    persist_broken_selection_event(conversation_id, error_message, payload)
  end

  # STRING keys exactly (the SPA consumes these verbatim). `requested_by` is
  # "id" | "key"; `requested_value` is the stale ask; `fallback_key` is the
  # model actually resolved; `scope` is "conversation" | "user".
  defp broken_selection_payload(
         %Resolution{requested_selection: %{by: by, value: value}} = res,
         scope
       ) do
    %{
      "kind" => "broken_model_selection",
      "requested_by" => Atom.to_string(by),
      "requested_value" => value,
      "fallback_key" => fallback_key(res.model),
      "scope" => scope
    }
  end

  defp fallback_key(%{key: key}) when is_binary(key), do: key
  defp fallback_key(_), do: nil

  defp broken_selection_message do
    ErrorMessages.format_user_friendly_error(
      :broken_model_selection,
      "The model you selected is no longer available. Reset to the default and retry, or pick another model."
    )
  end

  defp persist_broken_selection_event(conversation_id, text, payload) do
    Magus.Chat.upsert_event_message!(
      Ash.UUID.generate(),
      text,
      conversation_id,
      payload,
      true,
      authorize?: false
    )

    nil
  rescue
    exception ->
      Logger.warning(
        "Failed to persist broken-selection event for conversation #{conversation_id}: " <>
          Exception.message(exception)
      )

      nil
  end

  @doc """
  Derive the block scope from the same precedence `ModelKeyResolver` used
  (conversation > custom_agent > user).

  An id-based ask always came from the conversation's `selected_model_id` pin. A
  key-based ask is conversation-scoped when the stale key matches the
  conversation's (or its custom agent's) own selection for the mode; otherwise it
  inherited from the user default. Public so `MediaBypass` can reuse it.
  """
  def broken_selection_scope(%Resolution{requested_selection: %{by: :id}}, _conversation, _mode),
    do: "conversation"

  def broken_selection_scope(
        %Resolution{requested_selection: %{by: :key, value: key}},
        conversation,
        mode
      ) do
    if key in conversation_level_keys(conversation, mode), do: "conversation", else: "user"
  end

  def broken_selection_scope(_resolution, _conversation, _mode), do: "user"

  defp conversation_level_keys(conversation, mode) when is_map(conversation) do
    custom_agent =
      case Map.get(conversation, :custom_agent) do
        %Ash.NotLoaded{} -> nil
        value -> value
      end

    [
      model_key(conversation_selected_model(conversation, mode)),
      model_key(custom_agent_model(custom_agent, mode))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp conversation_level_keys(_conversation, _mode), do: []

  defp conversation_selected_model(conversation, :image_generation),
    do: Map.get(conversation, :selected_image_model)

  defp conversation_selected_model(conversation, :video_generation),
    do: Map.get(conversation, :selected_video_model)

  defp conversation_selected_model(conversation, _mode),
    do: Map.get(conversation, :selected_model)

  defp custom_agent_model(nil, _mode), do: nil
  defp custom_agent_model(agent, :image_generation), do: Map.get(agent, :image_model)
  defp custom_agent_model(agent, :video_generation), do: Map.get(agent, :video_model)
  defp custom_agent_model(agent, _mode), do: Map.get(agent, :model)

  defp model_key(%{key: key}) when is_binary(key), do: key
  defp model_key(_), do: nil

  def load_user_for_limits(user_id) do
    case Magus.Accounts.get_user(user_id, authorize?: false) do
      {:ok, user} ->
        user

      _ ->
        %{
          id: user_id,
          timezone: "Etc/UTC",
          data_region_preference: ["US", "EU", "CH"],
          data_region_consents: %{}
        }
    end
  end

  @doc """
  Check mode access, PAYG spend controls, and workspace model restriction.

  `workspace` may be `nil` (personal conversation), a workspace struct with
  `allowed_model_ids` loaded, or a binary workspace id (which triggers a DB
  lookup). Pass `nil` explicitly for non-workspace callers.
  """
  def check_usage_limit(user, mode, model, workspace) do
    alias Magus.Usage.PolicyEnforcer

    with {:ok, :allowed} <- PolicyEnforcer.check_mode_access(user, mode),
         {:ok, :allowed} <- PolicyEnforcer.check_usage(user, model) do
      PolicyEnforcer.check_workspace_model(workspace, model)
    end
  end

  defp resolve_workspace(%{workspace: %{allowed_model_ids: _} = workspace}, _conversation_id),
    do: workspace

  defp resolve_workspace(%{workspace_id: workspace_id}, _conversation_id)
       when is_binary(workspace_id) do
    case Ash.get(Magus.Workspaces.Workspace, workspace_id, authorize?: false) do
      {:ok, workspace} -> workspace
      _ -> nil
    end
  end

  defp resolve_workspace(_conversation, conversation_id) when is_binary(conversation_id) do
    case Magus.Chat.get_conversation(conversation_id, load: [:workspace], authorize?: false) do
      {:ok, %{workspace: %{} = workspace}} -> workspace
      _ -> nil
    end
  end

  defp resolve_workspace(_, _), do: nil

  defp build_request_context(conversation_id, state, data, mode, model, conversation_context) do
    base_tool_context = %{
      user_id: state[:user_id],
      conversation_id: conversation_id,
      acting_user_id: data[:acting_user_id] || data["acting_user_id"] || state[:user_id]
    }

    with {:ok, conversation} <- load_conversation_context(conversation_id, conversation_context) do
      # Always include workspace_id (nil for personal-context conversations) so
      # downstream tools can use it as an isolation key without checking key presence.
      base_tool_context =
        Map.put(base_tool_context, :workspace_id, conversation.workspace_id)

      # Enrich base tool context with brain IDs from signal data
      brain_id = data[:brain_id] || data["brain_id"]
      brain_page_id = data[:brain_page_id] || data["brain_page_id"]

      base_tool_context =
        if brain_id do
          base_tool_context
          |> Map.put(:brain_id, brain_id)
          |> Map.put(:brain_page_id, brain_page_id)
        else
          base_tool_context
        end

      active_draft_id = data[:active_draft_id] || data["active_draft_id"]
      message_id = sanitize_uuid(data[:message_id] || data["message_id"])
      text = data[:text] || data["text"] || ""
      attachments = normalize_attachment_ids(data[:attachments] || data["attachments"] || [])

      supports_tools? = is_map(model) and Map.get(model, :supports_tools?, true)

      {tools, tool_context} =
        build_tools_context(
          conversation,
          mode,
          active_draft_id,
          base_tool_context,
          supports_tools?
        )

      run_source = run_source_atom(data[:run_source] || data["run_source"])

      # Builder is the single source of truth for LLM context:
      # system prompt + memory + multiplayer + message history + attachments (with real image data)
      {system_prompt, initial_messages} =
        Builder.build_llm_context(
          conversation,
          message_id,
          text,
          attachments,
          mode,
          model,
          %{
            active_draft_id: active_draft_id,
            tools: tools,
            draft: data[:draft_selection],
            brain: data[:brain_selection],
            pdf: data[:pdf_selection],
            service: data[:service_selection],
            message_selections: data[:message_selections],
            brain_id: brain_id,
            brain_page_id: brain_page_id,
            source: run_source
          }
        )

      # Only pass initial_messages when message_id is present (ensures current
      # message is excluded from DB results). Without it, the strategy would
      # append the user query again, causing duplication.
      safe_initial =
        if message_id do
          initial_messages
        else
          Logger.warning(
            "Preflight: no message_id, dropping initial_messages to avoid duplication"
          )

          []
        end

      runtime_overrides = build_runtime_overrides(conversation, model)

      %{
        system_prompt: system_prompt,
        tool_context: tool_context,
        tools: tools,
        max_iterations: runtime_overrides.max_iterations,
        llm_opts: runtime_overrides.llm_opts,
        initial_messages: safe_initial
      }
    else
      {:error, reason} ->
        Logger.warning(
          "Preflight context build failed for conversation #{conversation_id}: #{inspect(reason)}"
        )

        %{
          system_prompt: nil,
          tool_context: base_tool_context,
          tools: nil,
          max_iterations: nil,
          llm_opts: nil,
          initial_messages: []
        }
    end
  end

  defp load_conversation_context(_conversation_id, %{id: _} = conversation_context) do
    {:ok, conversation_context}
  end

  defp load_conversation_context(conversation_id, _conversation_context) do
    Magus.Chat.get_conversation(conversation_id,
      load: [
        :selected_model,
        :selected_image_model,
        :selected_video_model,
        :workspace,
        active_system_prompt: [:model],
        members: [:user],
        custom_agent: [:model, :image_model, :video_model],
        user: [:selected_model, :selected_image_model, :selected_video_model]
      ],
      authorize?: false
    )
  end

  defp build_tools_context(
         conversation,
         mode,
         active_draft_id,
         base_tool_context,
         supports_tools?
       ) do
    {tools, tool_contexts} =
      ToolBuilder.build_tools(mode, conversation, supports_tools?, active_draft_id, nil,
        brain_id: base_tool_context[:brain_id],
        brain_page_id: base_tool_context[:brain_page_id],
        acting_user_id: base_tool_context[:acting_user_id]
      )

    tool_context =
      base_tool_context
      |> Map.merge(shared_tool_context(tool_contexts))
      |> maybe_put_per_tool_contexts(per_tool_contexts(tools, tool_contexts))

    {tools, tool_context}
  end

  defp per_tool_contexts(tools, tool_contexts) do
    Enum.reduce(tools, %{}, fn tool, acc ->
      tool_name = tool.name()

      per_context =
        Map.get(tool_contexts, tool) ||
          Map.get(tool_contexts, tool_name) ||
          Map.get(tool_contexts, to_string(tool)) ||
          %{}

      if is_map(per_context) and map_size(per_context) > 0 do
        Map.put(acc, tool_name, per_context)
      else
        acc
      end
    end)
  end

  defp shared_tool_context(tool_contexts) when is_map(tool_contexts) do
    contexts =
      tool_contexts
      |> Map.values()
      |> Enum.filter(&is_map/1)

    case contexts do
      [] ->
        %{}

      [first | rest] ->
        Enum.reduce(rest, first, fn context, acc ->
          Enum.reduce(acc, %{}, fn {key, value}, shared ->
            if Map.has_key?(context, key) and Map.get(context, key) == value do
              Map.put(shared, key, value)
            else
              shared
            end
          end)
        end)
    end
  end

  defp shared_tool_context(_), do: %{}

  defp maybe_put_per_tool_contexts(context, per_tool) do
    if is_map(per_tool) and map_size(per_tool) > 0 do
      Map.put(context, :__tool_contexts__, per_tool)
    else
      context
    end
  end

  defp build_runtime_overrides(conversation, model) do
    %{
      max_iterations: custom_agent_max_iterations(conversation.custom_agent),
      llm_opts:
        build_llm_opts(
          effective_sampling_settings(conversation),
          maybe_session_id(model, conversation_id(conversation))
        )
    }
  end

  # `openrouter_session_id` is only valid for the OpenRouter provider's option
  # schema. Passing it to any other provider (e.g. :publicai for the Swiss
  # Apertus models, or :openrouter_citations for Perplexity Sonar) makes
  # ReqLLM's `NimbleOptions.validate!` raise "unknown options" and the LLM call
  # fails. So only attach the sticky session id for OpenRouter-provider models;
  # for every other provider return nil and `build_llm_opts/2` omits the key.
  @doc false
  def maybe_session_id(model, conversation_id) do
    if openrouter_provider?(model), do: conversation_id, else: nil
  end

  defp openrouter_provider?(%{api_provider: provider}),
    do: provider in [:openrouter, "openrouter"]

  defp openrouter_provider?(_), do: false

  # Pure helper (unit-testable without a DB): merge a stable
  # `openrouter_session_id` into the conversation's sampling settings so
  # OpenRouter routes consecutive turns to the same provider, keeping its
  # prompt cache warm. The session id MUST be stable per conversation and free
  # of per-message entropy — we use the conversation UUID.
  #
  # `sampling` may be nil, a map with string keys (conversation
  # `sampling_settings` JSONB) or a map with atom keys (custom-agent settings).
  # Returns a map carrying `:openrouter_session_id` as an ATOM key alongside the
  # existing settings; the strategy's `normalize_llm_opts` accepts maps with
  # mixed-type keys and keeps any non-reserved atom key. When the conversation
  # id is missing we omit the key rather than passing nil.
  @doc false
  def build_llm_opts(sampling, conversation_id) do
    base = if is_map(sampling), do: sampling, else: %{}

    if is_binary(conversation_id) and conversation_id != "" do
      Map.put(base, :openrouter_session_id, conversation_id)
    else
      base
    end
  end

  defp conversation_id(conversation) when is_map(conversation) do
    case Map.get(conversation, :id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  defp conversation_id(_), do: nil

  defp custom_agent_max_iterations(%Ash.NotLoaded{}), do: nil

  defp custom_agent_max_iterations(custom_agent) when is_map(custom_agent) do
    value = Map.get(custom_agent, :max_iterations) || Map.get(custom_agent, "max_iterations")
    if is_integer(value) and value > 0, do: value, else: nil
  end

  defp custom_agent_max_iterations(_), do: nil

  defp effective_sampling_settings(conversation) do
    conversation_settings = Map.get(conversation, :sampling_settings)

    cond do
      is_map(conversation_settings) and map_size(conversation_settings) > 0 ->
        conversation_settings

      true ->
        custom_agent_sampling_settings(conversation.custom_agent)
    end
  end

  defp custom_agent_sampling_settings(%Ash.NotLoaded{}), do: nil

  defp custom_agent_sampling_settings(custom_agent) when is_map(custom_agent) do
    settings =
      Map.get(custom_agent, :sampling_settings) || Map.get(custom_agent, "sampling_settings")

    if is_map(settings) and map_size(settings) > 0 do
      settings
    else
      nil
    end
  end

  defp custom_agent_sampling_settings(_), do: nil

  defp maybe_put_runtime_field(payload, key, data) do
    value = Map.get(data, key) || Map.get(data, Atom.to_string(key))

    case value do
      nil -> payload
      "" -> payload
      [] -> payload
      value when is_map(value) and map_size(value) == 0 -> payload
      _ -> Map.put(payload, key, value)
    end
  end

  defp maybe_put_field(payload, _key, nil), do: payload
  defp maybe_put_field(payload, _key, ""), do: payload
  defp maybe_put_field(payload, key, value), do: Map.put(payload, key, value)

  defp sanitize_uuid(nil), do: nil

  defp sanitize_uuid(value) when is_binary(value) do
    uuid_regex = ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
    if Regex.match?(uuid_regex, value), do: value, else: nil
  end

  defp sanitize_uuid(_), do: nil

  defp normalize_attachment_ids(ids) when is_list(ids) do
    ids
    |> Enum.flat_map(fn
      id when is_binary(id) and id != "" -> [id]
      %{id: id} when is_binary(id) and id != "" -> [id]
      %{"id" => id} when is_binary(id) and id != "" -> [id]
      _ -> []
    end)
    |> Enum.uniq()
  end

  defp normalize_attachment_ids(_), do: []

  defp conversation_context_from_data(data) when is_map(data) do
    case Map.get(data, :conversation_context) || Map.get(data, "conversation_context") do
      %{} = conversation -> conversation
      _ -> nil
    end
  end

  defp conversation_context_from_data(_), do: nil

  defp preloaded_model_candidates(%{} = conversation) do
    custom_agent =
      case Map.get(conversation, :custom_agent) do
        %Ash.NotLoaded{} -> nil
        value -> value
      end

    user =
      case Map.get(conversation, :user) do
        %Ash.NotLoaded{} -> nil
        value -> value
      end

    [
      Map.get(conversation, :selected_model),
      Map.get(conversation, :selected_image_model),
      Map.get(conversation, :selected_video_model),
      model_from(custom_agent, :model),
      model_from(custom_agent, :image_model),
      model_from(custom_agent, :video_model),
      model_from(user, :selected_model),
      model_from(user, :selected_image_model),
      model_from(user, :selected_video_model)
    ]
    |> Enum.reject(fn
      nil -> true
      %Ash.NotLoaded{} -> true
      _ -> false
    end)
    |> Enum.uniq_by(fn model ->
      Map.get(model, :id) || Map.get(model, "id") || Map.get(model, :key) || Map.get(model, "key")
    end)
  end

  defp preloaded_model_candidates(_), do: []

  defp model_from(nil, _field), do: nil
  defp model_from(%Ash.NotLoaded{}, _field), do: nil
  defp model_from(value, field) when is_map(value), do: Map.get(value, field)
  defp model_from(_, _field), do: nil

  defp model_key_for_mode(model_keys, mode) when is_map(model_keys) do
    case mode do
      :image_generation -> model_keys[:image] || model_keys[:chat]
      :video_generation -> model_keys[:video] || model_keys[:chat]
      _ -> model_keys[:chat]
    end
  end

  defp model_key_for_mode(_model_keys, _mode), do: nil

  # Convert a run_source coming off a Jido signal payload into the atom form
  # that Builder/WakeupPreamble expect. Uses `String.to_existing_atom/1` so an
  # unrecognized source string falls back to nil (treated as :user_message).
  defp run_source_atom(value) when is_atom(value) and not is_nil(value), do: value

  defp run_source_atom(value) when is_binary(value) and value != "" do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp run_source_atom(_), do: nil

  # ---------------------------------------------------------------------------
  # Auto-routing: resolve :auto model key via AutoRouter
  # ---------------------------------------------------------------------------

  defp maybe_auto_route(%{chat: :auto} = model_keys, text, mode, conversation, metadata) do
    message = %{text: text, mode: mode, metadata: metadata}

    case AutoRouteResolver.resolve(model_keys, message, conversation) do
      {:ok, %{model_keys: resolved}} ->
        resolved

      _ ->
        %{model_keys | chat: Magus.Agents.Routing.ModelKeyResolver.default_model_key(:chat)}
    end
  rescue
    error ->
      Logger.warning("Preflight auto-route failed, using default: #{Exception.message(error)}")
      %{model_keys | chat: Magus.Agents.Routing.ModelKeyResolver.default_model_key(:chat)}
  end

  defp maybe_auto_route(model_keys, _text, _mode, _conversation, _metadata), do: model_keys

  defp build_route_metadata(data) do
    metadata = %{}

    metadata =
      if data[:pdf_selection] || data["pdf_selection"],
        do: Map.put(metadata, "pdf_selection", data[:pdf_selection] || data["pdf_selection"]),
        else: metadata

    if data[:service_selection] || data["service_selection"],
      do:
        Map.put(
          metadata,
          "service_selection",
          data[:service_selection] || data["service_selection"]
        ),
      else: metadata
  end

  # ---------------------------------------------------------------------------
  # Slash command helpers
  # ---------------------------------------------------------------------------

  defp get_agent_slash_commands(nil), do: []

  defp get_agent_slash_commands(%{} = conversation) do
    case Map.get(conversation, :custom_agent) do
      %Ash.NotLoaded{} -> []
      nil -> []
      agent -> Map.get(agent, :slash_commands, [])
    end
  end

  @doc false
  # Test seam: resolve + load a slash skill, returning the residual user text.
  def apply_slash_skill(raw_text, conversation_id, actor) do
    case SlashCommands.resolve(raw_text, [], actor: actor, conversation: nil) do
      {{:skill, ref}, remaining} ->
        load_slash_skill(ref, conversation_id, actor)
        remaining

      {_other, remaining} ->
        remaining
    end
  end

  defp load_slash_skill(ref, conversation_id, actor) do
    Magus.Skills.Loader.load(
      ref,
      %{conversation_id: conversation_id, user_id: actor && actor.id, user: actor},
      source: :slash_command
    )
  end

  defp load_actor(acting_user_id, conversation),
    do: resolve_slash_actor(acting_user_id, conversation)

  @doc false
  # Resolve the actor for explicit slash-skill visibility. Prefers the triggering
  # member (`acting_user_id`) so a non-owner in a shared conversation resolves
  # their OWN personal skills; falls back to the conversation owner when the
  # member is absent (autonomous turns) or fails to load, else nil. Extracted as a
  # public function so the member-vs-owner precedence is unit-testable.
  def resolve_slash_actor(acting_user_id, conversation) do
    load_user(acting_user_id) || load_conversation_owner(conversation)
  end

  defp load_user(nil), do: nil

  defp load_user(user_id) do
    case Magus.Accounts.get_user(user_id, authorize?: false) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  defp load_conversation_owner(nil), do: nil
  defp load_conversation_owner(%{user_id: owner_id}), do: load_user(owner_id)
  defp load_conversation_owner(_), do: nil

  # ---------------------------------------------------------------------------
  # Provider routing helpers
  # ---------------------------------------------------------------------------

  defp merge_provider_routing(llm_opts, nil), do: llm_opts

  defp merge_provider_routing(llm_opts, routing) when is_map(routing) do
    # Use atom key :openrouter_provider — ReqLLM reads request.options[:openrouter_provider]
    base = if is_map(llm_opts), do: llm_opts, else: %{}
    Map.put(base, :openrouter_provider, routing)
  end

  defp handle_region_unavailable(conversation_id, message_id) do
    error_message =
      "This model is not available in your enabled data regions. Update your data region preferences in settings."

    Logger.info("Region unavailable for conversation #{conversation_id}")

    Signals.error(conversation_id, message_id, :region_unavailable, error_message)
    Signals.state_change(conversation_id, :idle)
    Signals.response_complete(conversation_id, %{})

    ErrorMessages.create_error_event(
      conversation_id,
      :region_unavailable,
      %RuntimeError{message: error_message}
    )
  end
end
