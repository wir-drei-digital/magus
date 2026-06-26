defmodule Magus.Chat.SkillConversation do
  @moduledoc """
  Creates a conversation seeded with a skill's context + tools and sends its
  start message. Backs the classic `?skill=<name>&topic=<t>` deeplink
  (see `MagusWeb.Workbench.Chat.UrlActions.start_skill_conversation/3`) so the
  SvelteKit landing can start the same skill-seeded chat.
  """
  alias Magus.Agents.Skills

  @doc """
  Looks up the skill, creates a conversation under `actor` seeded with the
  skill's context/tools, then sends the start message asynchronously (the agent
  reply streams in once the caller navigates to the conversation).

  Returns `{:ok, conversation}` or `{:error, reason}` (unknown skill, create
  failure).
  """
  @spec start(String.t(), String.t() | nil, Ecto.UUID.t() | nil, struct()) ::
          {:ok, struct()} | {:error, term()}
  def start(skill_name, topic, workspace_id, actor) do
    with {:ok, skill} <- Skills.Registry.get_skill(skill_name),
         {:ok, conversation} <- create_conversation(skill, workspace_id, actor) do
      send_start_message(conversation, actor, skill_name, topic)
      {:ok, conversation}
    end
  end

  defp create_conversation(skill, workspace_id, actor) do
    %{skill_context: skill.content, skill_tools: skill.tools, workspace_id: workspace_id}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Magus.Chat.create_conversation(actor: actor)
  end

  defp send_start_message(conversation, actor, skill_name, topic) do
    Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
      language = to_string(actor.language)

      start_text =
        if topic, do: "Start: #{topic} [lang=#{language}]", else: "Start [lang=#{language}]"

      metadata =
        %{"wizard" => true, "skill" => skill_name, "action_card" => true}
        |> maybe_put_topic(topic)

      Magus.Chat.send_user_message(
        %{text: start_text, mode: :chat, conversation_id: conversation.id, metadata: metadata},
        actor: actor
      )
    end)
  end

  defp maybe_put_topic(metadata, nil), do: metadata
  defp maybe_put_topic(metadata, topic), do: Map.put(metadata, "topic", topic)
end
