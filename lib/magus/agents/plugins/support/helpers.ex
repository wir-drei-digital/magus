defmodule Magus.Agents.Plugins.Support.Helpers do
  @moduledoc false
  # Pure state extraction and formatting utilities for conversation plugins.

  @known_model_key_atoms ~w(chat image video)a

  @doc "Normalize model_keys to atom keys. Only converts known keys (chat, image, video)."
  def normalize_model_keys(model_keys) when is_map(model_keys) do
    Map.new(model_keys, fn
      {k, v} when is_atom(k) ->
        {k, v}

      {k, v} when is_binary(k) ->
        atom = Enum.find(@known_model_key_atoms, &(Atom.to_string(&1) == k))
        if atom, do: {atom, v}, else: {k, v}
    end)
  end

  def normalize_model_keys(other), do: other || %{}

  @doc "Extract the conversation UUID from agent state or agent ID."
  def get_conversation_id(agent) do
    state = agent.state || %{}
    state[:conversation_id] || extract_conversation_id_from_agent_id(agent.id)
  end

  @doc "Derive the deterministic response message ID from the active request."
  def get_current_message_id(agent) do
    request_id = get_active_request_id(agent)
    if request_id, do: response_id_for_request(request_id), else: nil
  end

  @doc """
  Derive a deterministic response message ID for a specific LLM turn.

  This mirrors main-branch semantics where each turn (iteration) streams/persists
  to its own message row.
  """
  def response_id_for_turn(request_id, iteration)
      when is_binary(request_id) and request_id != "" and is_integer(iteration) and iteration > 0 do
    deterministic_uuid("magus:response_turn", "#{request_id}:#{iteration}")
  end

  def response_id_for_turn(request_id, _iteration), do: response_id_for_request(request_id)

  @doc "Get the parent (user) message ID from strategy state."
  def get_parent_message_id(agent) do
    get_active_request_id(agent)
  end

  @doc "Read the strategy's active_request_id."
  def get_active_request_id(agent) do
    state = agent.state || %{}
    strategy_state = state[:__strategy__] || %{}
    strategy_state[:active_request_id]
  end

  @doc """
  The user to attribute/bill for the current turn: the sender of the triggering
  message `message_id`. In a shared (multiplayer/workspace) conversation this is
  the member who actually sent the message, not the conversation owner. Falls back
  to the agent's owner (`state[:user_id]`) when there is no resolvable triggering
  message (autonomous heartbeat/resume turns, or a load failure).
  """
  def acting_user_id(agent, message_id) do
    owner = (agent.state || %{})[:user_id]

    with true <- valid_message_id?(message_id),
         {:ok, %{created_by_id: sender}} when is_binary(sender) <-
           Ash.get(Magus.Chat.Message, message_id, authorize?: false) do
      sender
    else
      _ -> owner
    end
  rescue
    _ -> (agent.state || %{})[:user_id]
  end

  @doc "Read the strategy state map from the agent."
  def get_strategy_state(agent) do
    state = agent.state || %{}
    state[:__strategy__] || %{}
  end

  @doc """
  Derive a deterministic UUID for the response message from the user's message UUID.

  Uses MD5 hashing to produce a reproducible UUID v4 from the request ID. This ensures
  the same response ID is used during streaming AND persistence, even though the plugin
  can't store per-request state.
  """
  def response_id_for_request(nil) do
    require Logger
    Logger.warning("response_id_for_request called with nil request_id, using random UUID")
    Ash.UUID.generate()
  end

  def response_id_for_request(request_id) do
    deterministic_uuid("magus:response", request_id)
  end

  @doc """
  Derive a deterministic UUID for tool lifecycle events from ReAct `call_id`.

  This keeps `tool.start`/`tool.complete` event IDs stable and aligned with
  persisted event message IDs.
  """
  def tool_event_id_for_call_id(call_id) when is_binary(call_id) and call_id != "" do
    deterministic_uuid("magus:tool_event", call_id)
  end

  def tool_event_id_for_call_id(_), do: Ash.UUID.generate()

  @doc "Extract mode from signal data or agent state, normalizing to atom."
  def get_mode(state, signal) do
    data = signal.data || %{}
    raw_mode = data[:mode] || data["mode"] || state[:mode] || :chat
    normalize_mode(raw_mode)
  end

  @doc "Build custom agent metadata opts for signal broadcasts."
  def custom_agent_opts(agent) do
    state = agent.state || %{}
    opts = []

    opts =
      if state[:custom_agent_id],
        do: [custom_agent_id: state[:custom_agent_id]] ++ opts,
        else: opts

    opts =
      if state[:custom_agent_name],
        do: [custom_agent_name: state[:custom_agent_name]] ++ opts,
        else: opts

    opts
  end

  @doc """
  Extract the request_id from a ReAct `call_id`.

  Call IDs have the format `call_{request_id}_{iteration}_{llm_call_uuid}`.
  The request_id is a UUID (36 chars) immediately after the `call_` prefix.

  This is needed because Jido's ReAct strategy clears `active_request_id`
  before signals reach the plugin pipeline, so we can't rely on strategy
  state during signal processing.
  """
  def extract_request_id_from_call_id("call_" <> rest) do
    case Regex.run(~r/^(.+)_\d+_[^_]+$/, rest, capture: :all_but_first) do
      [request_id] when is_binary(request_id) and request_id != "" ->
        request_id

      _ ->
        if byte_size(rest) >= 36, do: String.slice(rest, 0, 36), else: nil
    end
  end

  def extract_request_id_from_call_id(_), do: nil

  @doc """
  Extract the iteration integer from a ReAct `call_id` when present.
  """
  def extract_iteration_from_call_id("call_" <> rest) do
    case Regex.run(~r/^.+_(\d+)_[^_]+$/, rest, capture: :all_but_first) do
      [iteration] ->
        case Integer.parse(iteration) do
          {value, ""} when value > 0 -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end

  def extract_iteration_from_call_id(_), do: nil

  @doc "Format error values to readable strings."
  def format_error({:cancelled, reason}), do: "Cancelled: #{inspect(reason)}"
  def format_error(error) when is_binary(error), do: error
  def format_error(%{message: msg}) when is_binary(msg), do: msg
  def format_error(error) when is_exception(error), do: Exception.message(error)
  def format_error(error), do: inspect(error)

  # ============================================================================
  # Shared helpers extracted from plugin private functions
  # ============================================================================

  @doc "Check if a message ID is a non-empty binary string."
  def valid_message_id?(id), do: is_binary(id) and id != ""

  @doc "Resolve the request_id from signal data or by extracting from call_id."
  def resolve_request_id(data, call_id) do
    data[:request_id] ||
      data["request_id"] ||
      extract_request_id_from_call_id(call_id)
  end

  @doc "Resolve the iteration from signal data or by extracting from call_id."
  def resolve_iteration(data, call_id) do
    data[:iteration] ||
      data["iteration"] ||
      extract_iteration_from_call_id(call_id)
  end

  @doc "Resolve the turn-specific message ID from signal data, agent state, and call metadata."
  def resolve_turn_message_id(data, agent, request_id, call_id) do
    explicit = data[:message_id] || data["message_id"]
    iteration = resolve_iteration(data, call_id)

    cond do
      valid_message_id?(explicit) ->
        explicit

      valid_message_id?(request_id) and is_integer(iteration) and iteration > 0 ->
        response_id_for_turn(request_id, iteration)

      valid_message_id?(request_id) ->
        response_id_for_request(request_id)

      true ->
        get_current_message_id(agent)
    end
  end

  @doc "Return the first non-blank binary from a list of values, or the default empty string."
  def first_non_blank(values) when is_list(values) do
    Enum.find(values, "", fn
      value when is_binary(value) -> value != ""
      _ -> false
    end)
  end

  # --- Private ---

  defp extract_conversation_id_from_agent_id("conv:" <> uuid), do: uuid
  defp extract_conversation_id_from_agent_id(_), do: nil

  defp deterministic_uuid(namespace, value) when is_binary(namespace) and is_binary(value) do
    hash = :crypto.hash(:md5, "#{namespace}:#{value}")
    <<a::48, _::4, b::12, _::2, c::62>> = hash

    <<a::48, 4::4, b::12, 2::2, c::62>>
    |> Base.encode16(case: :lower)
    |> then(fn hex ->
      <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
      "#{p1}-#{p2}-#{p3}-#{p4}-#{p5}"
    end)
  end

  defp normalize_mode(mode) when is_atom(mode), do: mode

  defp normalize_mode(mode) when is_binary(mode) do
    case mode do
      "chat" -> :chat
      "search" -> :search
      "reasoning" -> :reasoning
      "image_generation" -> :image_generation
      "video_generation" -> :video_generation
      _ -> :chat
    end
  end

  defp normalize_mode(_), do: :chat
end
