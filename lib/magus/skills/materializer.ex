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
         :ok <- ensure_env(conversation_id, user_id),
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

  # Ensure the agent's :sandbox_env secrets are available as /workspace/.env so
  # the skill's scripts can `source` them. Mirrors ExecCommand's injection; a
  # conversation without a custom agent simply gets no env file.
  defp ensure_env(conversation_id, user_id) do
    with {:ok, conversation} <- Magus.Chat.get_conversation(conversation_id, authorize?: false),
         agent_id when not is_nil(agent_id) <- conversation.custom_agent_id,
         {:ok, env_map} when map_size(env_map) > 0 <-
           Magus.Agents.sandbox_env_map_for_agent(agent_id, authorize?: false) do
      content =
        Enum.map_join(env_map, "\n", fn {k, v} ->
          "export #{k}='#{String.replace(v, "'", "'\\''")}'"
        end)

      case Orchestrator.write_file(conversation_id, "/workspace/.env", content, user_id: user_id) do
        {:ok, _} -> :ok
        other -> normalize(other)
      end
    else
      _ -> :ok
    end
  end

  defp normalize({:error, reason, _details}), do: {:error, reason}
  defp normalize(other), do: other
end
