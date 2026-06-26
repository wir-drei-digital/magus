defmodule MagusWeb.Workbench.Chat.UrlActions do
  @moduledoc """
  Handles chat-mode URL query params (`?skill=`, `?agent=`, `?use_prompt=`)
  that arrive on the workbench root and chat-conversation routes.

  - `?skill=` creates a fresh conversation seeded with the skill context
    and navigates to it (returns a redirected socket).
  - `?agent=` and `?use_prompt=` stash a `PendingChatAction` for the
    new-chat ConversationView to consume on mount.
  """

  use MagusWeb, :verified_routes
  import Phoenix.LiveView, only: [push_navigate: 2]

  alias Magus.Agents.Skills
  alias MagusWeb.Workbench.Chat.PendingChatAction
  alias MagusWeb.Workbench.Signals

  @spec handle(Phoenix.LiveView.Socket.t(), params :: map()) :: Phoenix.LiveView.Socket.t()
  def handle(socket, %{"skill" => skill_name} = params)
      when is_binary(skill_name) and skill_name != "" do
    start_skill_conversation(socket, skill_name, params["topic"])
  end

  def handle(socket, %{"agent" => agent_param})
      when is_binary(agent_param) and agent_param != "" do
    user = socket.assigns.current_user

    with {:ok, agent} <- lookup_agent_by_handle_or_id(agent_param, user) do
      PendingChatAction.put(user.id, {:set_custom_agent, agent})
    end

    socket
  end

  def handle(socket, %{"use_prompt" => prompt_id})
      when is_binary(prompt_id) and prompt_id != "" do
    user = socket.assigns.current_user

    with {:ok, prompt} <- Magus.Library.get_prompt(prompt_id, actor: user, load: [:model]) do
      PendingChatAction.put(user.id, prompt_action(prompt))
    end

    socket
  end

  def handle(socket, _params), do: socket

  @doc """
  Returns true if the params encode a chat URL action (`?agent`, `?use_prompt`,
  `?skill`). Used by routing to decide whether to force a fresh chat tab
  on the `:default` action.
  """
  @spec has_action?(map()) :: boolean()
  def has_action?(params) when is_map(params) do
    Enum.any?(["agent", "use_prompt", "skill"], fn key ->
      case params[key] do
        v when is_binary(v) and v != "" -> true
        _ -> false
      end
    end)
  end

  def has_action?(_), do: false

  @doc """
  Applies a `?use_prompt=` URL action to an already-open conversation.
  The PromptView's "Insert into current chat" button navigates to
  `/chat/<conv-id>?use_prompt=<PID>` so the prompt activates on the live,
  already-mounted ConversationView via PubSub broadcasts on the tab topic.
  """
  @spec apply_use_prompt_to_existing_conversation(Phoenix.LiveView.Socket.t(), map(), map()) ::
          Phoenix.LiveView.Socket.t()
  def apply_use_prompt_to_existing_conversation(socket, conv, %{"use_prompt" => prompt_id})
      when is_binary(prompt_id) and prompt_id != "" do
    user = socket.assigns.current_user
    tab_id = socket.assigns.active_tab_id

    case Magus.Library.get_prompt(prompt_id, actor: user, load: [:model]) do
      {:ok, prompt} ->
        apply_prompt_to_conversation(socket, conv, prompt, tab_id, user)

      _ ->
        socket
    end
  end

  def apply_use_prompt_to_existing_conversation(socket, _conv, _params), do: socket

  defp apply_prompt_to_conversation(socket, conv, %{type: :system} = prompt, tab_id, user)
       when is_binary(tab_id) do
    case Magus.Chat.activate_system_prompt(conv, prompt.id, actor: user) do
      {:ok, _} -> Signals.broadcast_active_prompt(tab_id, prompt)
      _ -> :ok
    end

    socket
  end

  defp apply_prompt_to_conversation(
         socket,
         _conv,
         %{type: :user, content: content},
         tab_id,
         _user
       )
       when is_binary(tab_id) and is_binary(content) and content != "" do
    Signals.broadcast_insert_text(tab_id, content)
    socket
  end

  defp apply_prompt_to_conversation(socket, _conv, _prompt, _tab_id, _user), do: socket

  defp prompt_action(%{type: :system} = prompt), do: {:activate_system_prompt, prompt}
  defp prompt_action(%{type: :user} = prompt), do: {:insert_text, prompt.content}

  defp lookup_agent_by_handle_or_id(param, actor) do
    case Ecto.UUID.cast(param) do
      {:ok, id} -> Magus.Agents.get_custom_agent(id, actor: actor, load: [:image_url])
      :error -> Magus.Agents.get_custom_agent_by_handle(param, actor: actor, load: [:image_url])
    end
  end

  defp start_skill_conversation(socket, skill_name, topic) do
    user = socket.assigns.current_user
    workspace_id = socket.assigns[:workspace_id]

    with {:ok, skill} <- Skills.Registry.get_skill(skill_name),
         {:ok, conversation} <- create_skill_conversation(skill, workspace_id, user) do
      send_skill_start_message(conversation, user, skill_name, topic)
      push_navigate(socket, to: ~p"/chat/#{conversation.id}")
    else
      _ -> socket
    end
  end

  defp create_skill_conversation(skill, workspace_id, user) do
    %{
      skill_context: skill.content,
      skill_tools: skill.tools,
      workspace_id: workspace_id
    }
    |> Map.reject(fn {_k, v} -> is_nil(v) end)
    |> Magus.Chat.create_conversation(actor: user)
  end

  defp send_skill_start_message(conversation, user, skill_name, topic) do
    Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
      language = to_string(user.language)

      start_text =
        if topic, do: "Start: #{topic} [lang=#{language}]", else: "Start [lang=#{language}]"

      metadata =
        %{"wizard" => true, "skill" => skill_name, "action_card" => true}
        |> maybe_put_topic(topic)

      Magus.Chat.send_user_message(
        %{
          text: start_text,
          mode: :chat,
          conversation_id: conversation.id,
          metadata: metadata
        },
        actor: user
      )
    end)
  end

  defp maybe_put_topic(metadata, nil), do: metadata
  defp maybe_put_topic(metadata, topic), do: Map.put(metadata, "topic", topic)
end
