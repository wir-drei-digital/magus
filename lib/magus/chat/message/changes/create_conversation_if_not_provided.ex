defmodule Magus.Chat.Message.Changes.CreateConversationIfNotProvided do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, context) do
    if changeset.arguments[:conversation_id] do
      Ash.Changeset.force_change_attribute(
        changeset,
        :conversation_id,
        changeset.arguments.conversation_id
      )
    else
      Ash.Changeset.before_action(changeset, fn changeset ->
        folder_id = changeset.arguments[:folder_id]
        workspace_id = changeset.arguments[:workspace_id]
        chat_mode = Ash.Changeset.get_attribute(changeset, :mode)
        custom_agent_id = changeset.arguments[:custom_agent_id]
        system_prompt_id = changeset.arguments[:system_prompt_id]

        # If no agent specified, resolve the appropriate default agent.
        # Workspace-scoped conversations use the workspace's shared default,
        # personal conversations use the user's personal default.
        custom_agent_id =
          custom_agent_id ||
            resolve_default_agent_id(workspace_id, Ash.Context.to_opts(context))

        conversation_params =
          %{
            folder_id: folder_id,
            chat_mode: chat_mode,
            custom_agent_id: custom_agent_id,
            workspace_id: workspace_id
          }
          |> Map.reject(fn {_k, v} -> is_nil(v) end)

        opts = Ash.Context.to_opts(context)
        conversation = Magus.Chat.create_conversation!(conversation_params, opts)

        # Activate system prompt on the new conversation if one was selected
        if system_prompt_id do
          case Magus.Chat.activate_system_prompt(conversation, system_prompt_id, opts) do
            {:ok, _} ->
              :ok

            {:error, reason} ->
              require Logger

              Logger.warning(
                "Failed to activate system prompt #{system_prompt_id}: #{inspect(reason)}"
              )
          end
        end

        # Increment agent use count in the background
        if custom_agent_id do
          Task.Supervisor.start_child(Magus.AgentLoopTaskSupervisor, fn ->
            case Magus.Agents.get_custom_agent(custom_agent_id, authorize?: false) do
              {:ok, agent} ->
                Magus.Agents.increment_agent_use_count(agent, authorize?: false)

              _ ->
                :ok
            end
          end)
        end

        Ash.Changeset.force_change_attribute(changeset, :conversation_id, conversation.id)
      end)
    end
  end

  defp resolve_default_agent_id(workspace_id, opts) do
    actor = opts[:actor]

    cond do
      is_nil(actor) ->
        nil

      is_binary(workspace_id) ->
        case Magus.Agents.ensure_workspace_default_agent(workspace_id, actor) do
          {:ok, agent} -> agent.id
          _ -> nil
        end

      true ->
        case Magus.Agents.ensure_default_agent(actor) do
          {:ok, agent} -> agent.id
          _ -> nil
        end
    end
  end
end
