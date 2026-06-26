defmodule Magus.Agents.Support.MentionParser do
  @moduledoc """
  Parses @mentions from chat message text and resolves them to custom agents.

  Handles are lowercase alphanumeric + hyphens (e.g., `@my-agent`).
  Returns at most 3 unique mentioned agents per message.

  Resolution is scoped by conversation context:

    * In a workspace conversation, only that workspace's agents are mentionable.
    * In a personal conversation, only the user's personal (non-workspace)
      agents are mentionable.
  """

  require Ash.Query

  @max_mentions 3
  # Match @handle only when preceded by whitespace or at start of string.
  # This prevents matching email addresses like user@example.
  # Handles: lowercase alphanumeric + hyphens, no leading hyphen.
  @mention_regex ~r/(?:^|(?<=\s))@([a-z0-9][a-z0-9-]*)/

  @doc """
  Parse @mentions from text and resolve to custom agents in the given scope.

  Returns a list of `{handle, %CustomAgent{}}` tuples (max 3, deduplicated).
  Unrecognized handles are silently ignored.
  """
  def parse(text, user_id, workspace_id \\ nil)

  def parse(_text, nil, _workspace_id), do: []

  def parse(text, user_id, workspace_id) when is_binary(text) do
    handles =
      @mention_regex
      |> Regex.scan(text)
      |> Enum.map(fn [_full, handle] -> String.downcase(handle) end)
      |> Enum.uniq()
      |> Enum.take(@max_mentions)

    case handles do
      [] ->
        []

      handles ->
        agents =
          scope_query(user_id, workspace_id)
          |> Ash.Query.filter(handle in ^handles)
          |> Ash.Query.load([:model, :image_model, :video_model])
          |> Ash.read!(authorize?: false)

        agent_by_handle = Map.new(agents, fn a -> {a.handle, a} end)

        handles
        |> Enum.flat_map(fn handle ->
          case Map.get(agent_by_handle, handle) do
            nil -> []
            agent -> [{handle, agent}]
          end
        end)
        |> Enum.reject(fn {_handle, agent} -> agent.is_default end)
    end
  end

  def parse(_, _, _), do: []

  defp scope_query(_user_id, workspace_id) when is_binary(workspace_id) do
    Magus.Agents.CustomAgent
    |> Ash.Query.filter(workspace_id == ^workspace_id)
  end

  defp scope_query(user_id, nil) do
    Magus.Agents.CustomAgent
    |> Ash.Query.filter(user_id == ^user_id and is_nil(workspace_id))
  end

  @doc """
  Strip @handle tokens from text and clean up whitespace.
  Only strips handles that were actually resolved to agents.
  """
  def strip_mentions(text, handles) when is_binary(text) and is_list(handles) do
    # Handles are constrained to [a-z0-9-], so literal replacement is safe
    Enum.reduce(handles, text, fn handle, acc ->
      String.replace(acc, "@" <> handle, "")
    end)
    |> String.replace(~r/\s{2,}/, " ")
    |> String.trim()
  end

  def strip_mentions(text, _), do: text
end
