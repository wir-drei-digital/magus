defmodule Magus.Agents.Reactors.ExtractMemories do
  @moduledoc """
  Orchestrates memory extraction from a conversation turn.

  This reactor is typically called after an agent response is complete
  to analyze the user message and agent response for extractable memories.

  ## Flow

  1. Loads existing memories for context
  2. Analyzes the conversation turn
  3. Determines scope for each extraction (local vs global)
  4. Creates or updates memories

  ## Usage

      Reactor.run(Magus.Agents.Reactors.ExtractMemories, %{
        user_id: user.id,
        conversation_id: conversation.id,
        user_message: "Remember that my favorite color is blue",
        agent_response: "I'll remember that your favorite color is blue."
      })

  ## Inputs

  - `user_id` - UUID of the user
  - `conversation_id` - UUID of the conversation
  - `user_message` - The user's message text
  - `agent_response` - The agent's response text

  ## Returns

      {:ok, %{extracted: 1, local: 1, global: 0}}
  """

  use Ash.Reactor

  require Logger

  # =============================================================================
  # Inputs
  # =============================================================================

  input :user_id
  input :conversation_id
  input :user_message
  input :agent_response

  # =============================================================================
  # Step 1: Load existing memories for context
  # =============================================================================

  step :load_existing_memories do
    argument :user_id, input(:user_id)
    argument :conversation_id, input(:conversation_id)

    run fn args, _context ->
      try do
        workspace_id = Magus.Memory.workspace_id_for_conversation(args.conversation_id)

        local_memories =
          Magus.Memory.list_memories_for_conversation!(
            args.conversation_id,
            %{limit: 10},
            authorize?: false
          )

        user_memories =
          Magus.Memory.list_user_memories!(
            workspace_id,
            %{limit: 10},
            actor: %Magus.Agents.Support.AiAgent{},
            authorize?: false
          )

        {:ok, %{local: local_memories, user: user_memories}}
      rescue
        e ->
          Logger.warning("Failed to load existing memories: #{Exception.message(e)}")
          {:ok, %{local: [], user: []}}
      end
    end
  end

  # =============================================================================
  # Step 2: Analyze turn and extract memories using LLM
  # =============================================================================

  step :analyze_turn do
    argument :user_id, input(:user_id)
    argument :conversation_id, input(:conversation_id)
    argument :user_message, input(:user_message)
    argument :agent_response, input(:agent_response)
    argument :existing, result(:load_existing_memories)

    run fn args, _context ->
      # Skip if messages are too short
      if String.length(args.user_message || "") < 10 and
           String.length(args.agent_response || "") < 20 do
        {:ok, %{extractions: []}}
      else
        case Magus.Agents.Actions.ExtractTurnMemories.run(
               %{
                 user_id: to_string(args.user_id),
                 conversation_id: to_string(args.conversation_id),
                 user_message: args.user_message || "",
                 agent_response: args.agent_response || ""
               },
               %{}
             ) do
          {:ok, result} ->
            {:ok, result}

          {:error, reason} ->
            Logger.warning("Memory extraction failed: #{inspect(reason)}")
            {:ok, %{extractions: [], error: reason}}
        end
      end
    end
  end

  # =============================================================================
  # Step 3: Summarize results
  # =============================================================================

  step :summarize do
    argument :analysis, result(:analyze_turn)

    run fn args, _context ->
      extractions = Map.get(args.analysis, :extractions, [])
      applied = Map.get(args.analysis, :applied_count, 0)

      local_count = Enum.count(extractions, fn e -> e[:scope] == :local end)
      user_count = Enum.count(extractions, fn e -> e[:scope] == :user end)

      Logger.debug(
        "ExtractMemories: Extracted #{applied} memories (#{local_count} local, #{user_count} user)"
      )

      # Emit telemetry
      if local_count > 0, do: Magus.Telemetry.memory_extracted(:local, local_count)
      if user_count > 0, do: Magus.Telemetry.memory_extracted(:user, user_count)

      {:ok, %{extracted: applied, local: local_count, user: user_count}}
    end
  end

  # =============================================================================
  # Return
  # =============================================================================

  return :summarize
end
