defmodule Magus.Agents.Plugins.InboxEventPlugin do
  @moduledoc """
  Plugin that detects @mentions in user messages and dispatches them to the
  mentioned custom agents.

  When a user message contains @handle mentions, this plugin:
  1. Parses mentions using MentionParser
  2. Dispatches directly to RunOrchestrator (skipping triage LLM) for each active
     mentioned agent via their home conversation
  3. Overrides with Noop so the main conversation agent does NOT also reply
     to the message

  Also handles approval response matching for pending approval events.

  Mention failures never block the normal conversation flow.
  """

  use Jido.Plugin,
    name: "inbox_event",
    state_key: :inbox_event,
    actions: [],
    description: "Detects @mentions in user messages and creates inbox events",
    signal_patterns: ["message.user"]

  require Logger

  alias Magus.Agents.Plugins.Support.Helpers
  alias Magus.Agents.Signals
  alias Magus.Agents.Support.HomeConversation
  alias Magus.Agents.Support.MentionParser
  alias Magus.Agents.RunOrchestrator

  @impl Jido.Plugin
  def mount(_agent, _config), do: {:ok, %{}}

  @impl Jido.Plugin
  def handle_signal(%{type: "message.user"} = signal, context) do
    agent = context[:agent]
    text = get_in(signal.data, [:text]) || get_in(signal.data, ["text"]) || ""
    user_id = get_in(agent.state, [:user_id]) || get_in(agent.state, ["user_id"])
    conversation_id = Helpers.get_conversation_id(agent)
    workspace_id = resolve_workspace_id(conversation_id)

    mentions = MentionParser.parse(text, user_id, workspace_id)
    all_handles = for {handle, _agent} <- mentions, do: handle
    active_mentions = for {_handle, agent} <- mentions, not agent.is_paused, do: agent
    stripped_text = MentionParser.strip_mentions(text, all_handles)

    dispatched =
      for mentioned_agent <- active_mentions,
          dispatch_mention_directly(
            mentioned_agent,
            user_id,
            conversation_id,
            stripped_text,
            signal
          ) ==
            :dispatched,
          do: mentioned_agent

    # Check for approval responses
    check_approval_response(signal, conversation_id, user_id)

    if dispatched != [] do
      Logger.debug(
        "InboxEventPlugin: dispatched to #{length(dispatched)} agent(s), suppressing main agent"
      )

      # Suppressing the main agent with a Noop skips the ReAct turn entirely, so
      # PersistencePlugin never emits the terminal signals that clear the UI's
      # "thinking" state. Emit them here (same pattern as the preflight Noop
      # paths) so the conversation doesn't stay stuck until the watchdog fires.
      if conversation_id do
        Signals.state_change(conversation_id, :idle)
        Signals.response_complete(conversation_id, %{})
      end

      {:ok, {:override, Jido.Actions.Control.Noop}}
    else
      {:ok, :continue}
    end
  rescue
    e ->
      Logger.warning(
        "InboxEventPlugin error: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}"
      )

      {:ok, :continue}
  end

  def handle_signal(_signal, _context), do: {:ok, :continue}

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp dispatch_mention_directly(mentioned_agent, user_id, conversation_id, stripped_text, signal) do
    case HomeConversation.ensure(user_id, mentioned_agent.id) do
      {:ok, home_conv} when home_conv.id == conversation_id ->
        # User is already in the mentioned agent's home conversation.
        # Let the agent handle the message normally instead of dispatching to itself.
        :skipped

      {:ok, home_conv} ->
        objective = String.slice(stripped_text, 0, 500)
        message_id = signal.data[:message_id] || signal.data["message_id"]
        model_key = agent_model_key(mentioned_agent)

        run_attrs = %{
          kind: :consult,
          source_conversation_id: conversation_id,
          source_message_id: valid_uuid(message_id),
          target_conversation_id: home_conv.id,
          target_agent_id: mentioned_agent.id,
          initiator_user_id: user_id,
          model_key: model_key,
          request_id: "mention-#{Ash.UUID.generate()}",
          objective: objective,
          idempotency_key: "mention:#{message_id}:#{mentioned_agent.id}",
          metadata: %{
            trigger: "mention",
            agent_name: mentioned_agent.name,
            agent_handle: mentioned_agent.handle
          }
        }

        case RunOrchestrator.enqueue(run_attrs) do
          {:ok, _run} ->
            :dispatched

          {:error, reason} ->
            Logger.warning("InboxEventPlugin: direct dispatch failed: #{inspect(reason)}")
            :skipped
        end

      _ ->
        :skipped
    end
  rescue
    e ->
      Logger.warning("InboxEventPlugin: direct dispatch error: #{inspect(e)}")
      :skipped
  end

  defp agent_model_key(%{model: %{key: key}}) when is_binary(key), do: key
  defp agent_model_key(_), do: nil

  defp resolve_workspace_id(nil), do: nil

  defp resolve_workspace_id(conversation_id) do
    case Magus.Chat.get_conversation(conversation_id, authorize?: false) do
      {:ok, %{workspace_id: workspace_id}} -> workspace_id
      _ -> nil
    end
  end

  @uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  defp valid_uuid(value) when is_binary(value) do
    if Regex.match?(@uuid_regex, value), do: value, else: nil
  end

  defp valid_uuid(_), do: nil

  defp check_approval_response(signal, conversation_id, user_id) do
    text = signal.data[:text] || signal.data["text"] || ""

    maybe_record_skill_approval(text, conversation_id, user_id)

    with {:ok, user} when not is_nil(user) <- Magus.Accounts.get_user(user_id, authorize?: false),
         false <- is_nil(conversation_id) or text == "",
         {:ok, [event | _]} <-
           Magus.Agents.get_waiting_approval(to_string(conversation_id), actor: user) do
      options = event.payload["options"] || []
      matched = Enum.find(options, fn opt -> String.starts_with?(text, "#{opt}:") end)

      if matched do
        Magus.Agents.resolve_event(
          event,
          %{resolved_by: :user, resolution_note: "User chose: #{matched}"},
          actor: user
        )
      end
    end

    :ok
  rescue
    e ->
      Logger.warning("InboxEventPlugin approval check error: #{inspect(e)}")
      :ok
  end

  # A user reply "Approve skill: <uuid>" records that skill as approved on the
  # conversation, gating bundled-skill materialization. Non-agent path: this is
  # the only way approval is recorded, so the agent cannot self-approve.
  defp maybe_record_skill_approval("Approve skill: " <> skill_id, conversation_id, user_id)
       when is_binary(conversation_id) do
    with {:ok, user} when not is_nil(user) <- Magus.Accounts.get_user(user_id, authorize?: false),
         {:ok, conversation} <- Magus.Chat.get_conversation(conversation_id, actor: user),
         {:ok, _} <-
           Magus.Chat.record_skill_approval(conversation, %{skill_id: String.trim(skill_id)},
             actor: user
           ) do
      :ok
    else
      error ->
        Logger.warning(
          "Skill approval not recorded (conversation #{conversation_id}): #{inspect(error)}"
        )

        :ok
    end
  rescue
    e ->
      Logger.warning("Skill approval record crashed: #{inspect(e)}")
      :ok
  end

  defp maybe_record_skill_approval(_text, _conversation_id, _user_id), do: :ok
end
