defmodule Magus.Agents.SubAgent.ResultEnrichment do
  @moduledoc """
  Pure helpers that summarize a sub-agent (child) conversation:
  files it created, tools it used. Shared between
  `Magus.Agents.Tools.Tasks.AwaitSubAgents` (legacy enrichment surface)
  and `Magus.Agents.SubAgent.SpawnOutput` (the new spawn-message-as-result
  delivery surface).
  """

  require Ash.Query
  require Logger

  alias Magus.Agents.Support.AiAgent

  @spec files_created(Ecto.UUID.t() | String.t() | nil) :: [map()]
  def files_created(nil), do: []

  def files_created(conversation_id) do
    case Magus.Files.list_files_for_conversation(conversation_id, actor: %AiAgent{}) do
      {:ok, files} ->
        Enum.map(files, fn f ->
          %{name: f.name, type: to_string(f.type), file_id: to_string(f.id)}
        end)

      _ ->
        []
    end
  rescue
    e ->
      Logger.warning("ResultEnrichment.files_created failed: #{Exception.message(e)}")
      []
  end

  @spec tools_used(Ecto.UUID.t() | String.t() | nil) :: %{
          names: [String.t()],
          count: non_neg_integer()
        }
  def tools_used(nil), do: %{names: [], count: 0}

  def tools_used(conversation_id) do
    messages =
      Magus.Chat.Message
      |> Ash.Query.filter(
        conversation_id == ^conversation_id and
          message_type == :event and
          not is_nil(tool_call_data)
      )
      |> Ash.read!(authorize?: false)

    names =
      messages
      |> Enum.map(fn msg -> (msg.tool_call_data || %{})["tool_name"] end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{names: names, count: length(messages)}
  rescue
    e ->
      Logger.warning("ResultEnrichment.tools_used failed: #{Exception.message(e)}")
      %{names: [], count: 0}
  end
end
