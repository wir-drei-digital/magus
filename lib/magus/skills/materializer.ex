defmodule Magus.Skills.Materializer do
  @moduledoc """
  Writes a bundled skill's files into the conversation's sandbox under
  /workspace/.skills/<name>/. Idempotent via a .materialized marker. Ensures
  the agent's secrets are present as /workspace/.env before scripts run.
  """

  alias Magus.Sandbox.Orchestrator
  alias Magus.Skills.Import.Unpack

  @spec materialize(Ecto.UUID.t(), map, Ecto.UUID.t()) :: {:ok, String.t()} | {:error, term}
  def materialize(conversation_id, skill, user_id) do
    dir = "/workspace/.skills/#{skill.name}"
    marker = "#{dir}/.materialized"

    if materialized?(conversation_id, marker, user_id) do
      {:ok, dir}
    else
      write_bundle(conversation_id, skill, user_id, dir, marker)
    end
  end

  defp write_bundle(conversation_id, skill, user_id, dir, marker) do
    with {:ok, bytes} <- Magus.Files.Storage.get(skill.bundle_path),
         {:ok, %{skill_md: md, files: files}} <- Unpack.unpack(bytes),
         :ok <- write_all(conversation_id, dir, [{"SKILL.md", md} | files], user_id),
         :ok <- ensure_env(conversation_id, skill, user_id),
         {:ok, _} <- Orchestrator.write_file(conversation_id, marker, "ok", user_id: user_id) do
      {:ok, dir}
    end
  end

  defp materialized?(conversation_id, marker, user_id) do
    match?({:ok, _}, Orchestrator.read_file(conversation_id, marker, user_id: user_id))
  end

  defp write_all(conversation_id, dir, files, user_id) do
    Enum.reduce_while(files, :ok, fn {path, content}, :ok ->
      case Orchestrator.write_file(conversation_id, "#{dir}/#{path}", content, user_id: user_id) do
        {:ok, _} -> {:cont, :ok}
        other -> {:halt, normalize(other)}
      end
    end)
  end

  # Build /workspace/.env from the agent's :sandbox_env secrets (if any) merged
  # with the user's declared skill secrets (only the keys the skill lists in
  # required_secrets). Skill-declared user secrets do NOT override agent secrets
  # on key conflict (the agent owner curated those for this context).
  # authorize?: false on the internal lookups: internal materialization step,
  # runs deep in the agent pipeline with no acting user.
  defp ensure_env(conversation_id, skill, user_id) do
    agent_env = agent_env_map(conversation_id)
    skill_env = declared_skill_env(skill, user_id)
    env = Map.merge(skill_env, agent_env)

    if map_size(env) == 0 do
      :ok
    else
      content =
        Enum.map_join(env, "\n", fn {k, v} ->
          "export #{k}='#{String.replace(v, "'", "'\\''")}'"
        end)

      case Orchestrator.write_file(conversation_id, "/workspace/.env", content, user_id: user_id) do
        {:ok, _} -> :ok
        other -> normalize(other)
      end
    end
  end

  defp agent_env_map(conversation_id) do
    with {:ok, conversation} <- Magus.Chat.get_conversation(conversation_id, authorize?: false),
         agent_id when not is_nil(agent_id) <- conversation.custom_agent_id,
         {:ok, env_map} when map_size(env_map) > 0 <-
           Magus.Agents.sandbox_env_map_for_agent(agent_id, authorize?: false) do
      env_map
    else
      _ -> %{}
    end
  end

  defp declared_skill_env(skill, user_id) do
    keys =
      (skill.required_secrets || [])
      |> Enum.map(fn
        %{"key" => k} -> k
        %{key: k} -> k
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)

    if user_id && keys != [], do: Magus.Skills.sandbox_env_for_user(user_id, keys), else: %{}
  end

  defp normalize({:error, reason, _details}), do: {:error, reason}
  defp normalize(other), do: other
end
