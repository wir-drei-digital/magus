defmodule Magus.Agents.Tools.Search.ActorContext do
  @moduledoc """
  Builds the actor-scoped context that `Magus.Agents.Tools.Catalog` resolution
  and search expect, shared by `load_tool` and `tool_search`.

  The MCP-aware catalog functions (`resolve/2`, `search/3`, `entries/1`) gate
  MCP tools on a real `%Magus.Accounts.User{}` under `:user`. The tool context
  passed to `run/2` sets `user: conversation.user`, which is NOT always loaded
  (it can be an `%Ash.NotLoaded{}`). So we:

    1. Use `context[:user]` only when it is a concrete `%User{}`.
    2. Otherwise load the actor record from `context[:user_id]` via
       `Magus.Accounts.get_user(user_id, authorize?: false)` -- the established
       pattern for fetching the actor in agent tools (see run_orchestrator.ex,
       spreadsheet/read_sheet.ex). Loading the actor is not a policy bypass; the
       loaded user is then handed to Catalog as the actor that authorizes MCP
       server reads.
    3. If there is no user and no loadable id, `user` is `nil`, and Catalog
       degrades to static-only (no MCP) -- the correct safe behavior.
  """

  alias Magus.Accounts.User

  import Magus.Agents.Tools.Helpers, only: [get_context_value: 2]

  @doc """
  Build the actor-scoped context map (`%{user:, user_id:, conversation_id:}`)
  from a tool `context`. `user` is a concrete `%User{}` or `nil`.
  """
  @spec from(map()) :: %{user: User.t() | nil, user_id: term(), conversation_id: term()}
  def from(context) do
    user_id = get_context_value(context, :user_id)

    user =
      case get_context_value(context, :user) do
        # Only a concrete User is a valid actor. A wildcard `%_{}` would also
        # match `%Ash.NotLoaded{}` and hand a bogus actor to Ash -> deny/crash.
        %User{} = u -> u
        _ -> load_user(user_id)
      end

    %{
      user: user,
      user_id: user_id,
      conversation_id: get_context_value(context, :conversation_id)
    }
  end

  defp load_user(nil), do: nil

  defp load_user(user_id) do
    case Magus.Accounts.get_user(user_id, authorize?: false) do
      {:ok, user} -> user
      _ -> nil
    end
  end
end
