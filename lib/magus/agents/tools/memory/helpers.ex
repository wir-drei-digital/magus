defmodule Magus.Agents.Tools.Memory.Helpers do
  @moduledoc """
  Helper functions specific to memory tools.

  For shared helpers (context extraction, error handling, etc.),
  see `Magus.Agents.Tools.Helpers`.
  """

  require Logger

  # Re-export shared helpers for convenience
  defdelegate get_context_value(context, key), to: Magus.Agents.Tools.Helpers
  defdelegate extract_error_message(error), to: Magus.Agents.Tools.Helpers
  defdelegate ai_actor(), to: Magus.Agents.Tools.Helpers
  defdelegate validate_context(context, required_keys), to: Magus.Agents.Tools.Helpers

  @doc """
  Formats a datetime for display in UTC.

  ## Examples

      iex> format_datetime(~U[2024-01-15 10:30:00Z])
      "2024-01-15 10:30"

      iex> format_datetime(nil)
      nil
  """
  @spec format_datetime(DateTime.t() | nil) :: String.t() | nil
  def format_datetime(nil), do: nil
  def format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  @doc """
  Finds a memory by name, handling NotFound errors (both bare and wrapped in Invalid).

  For global scope, uses a User struct as actor since `global_by_name` filters by `actor(:id)`.
  For local scope, uses `ai_actor()` since `by_name` takes conversation_id as an argument.

  Returns `{:ok, memory}`, `{:error, :not_found}`, or `{:error, reason}`.
  """
  @spec find_memory_by_name(String.t(), String.t(), map()) ::
          {:ok, any()} | {:error, :not_found} | {:error, any()}
  def find_memory_by_name(name, "user", ctx) do
    actor = %Magus.Accounts.User{id: ctx.user_id}
    workspace_id = Map.get(ctx, :workspace_id)

    case Magus.Memory.get_user_memory_by_name(workspace_id, name, actor: actor) do
      {:ok, memory} -> {:ok, memory}
      {:error, error} -> normalize_not_found(error)
    end
  end

  def find_memory_by_name(name, "agent", ctx) do
    case Magus.Memory.get_agent_memory_by_name(ctx.custom_agent_id, name, actor: ai_actor()) do
      {:ok, memory} -> {:ok, memory}
      {:error, error} -> normalize_not_found(error)
    end
  end

  def find_memory_by_name(name, _local, ctx) do
    case Magus.Memory.get_memory_by_name(ctx.conversation_id, name, actor: ai_actor()) do
      {:ok, memory} -> {:ok, memory}
      {:error, error} -> normalize_not_found(error)
    end
  end

  defp normalize_not_found(%Ash.Error.Query.NotFound{}), do: {:error, :not_found}

  defp normalize_not_found(%Ash.Error.Invalid{errors: errors}) do
    if Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1)) do
      {:error, :not_found}
    else
      {:error, errors}
    end
  end

  defp normalize_not_found(error), do: {:error, error}

  @valid_scopes ["local", "user", "agent"]

  @doc """
  Validates that the scope parameter is valid.

  Returns `{:ok, scope}` if valid, `{:error, message}` if invalid.

  ## Examples

      iex> validate_scope("local")
      {:ok, "local"}

      iex> validate_scope("user")
      {:ok, "user"}

      iex> validate_scope("agent")
      {:ok, "agent"}

      iex> validate_scope("invalid")
      {:error, "Invalid scope 'invalid'. Use 'local', 'global', or 'agent'."}
  """
  @spec validate_scope(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_scope(scope) when scope in @valid_scopes, do: {:ok, scope}

  def validate_scope(scope) do
    {:error, "Invalid scope '#{scope}'. Use 'local', 'user', or 'agent'."}
  end

  @valid_list_scopes ["local", "user", "agent", "all"]

  @doc """
  Validates that the scope parameter for list/search operations is valid.

  These operations also support "all" to list/search both scopes.

  ## Examples

      iex> validate_list_scope("all")
      {:ok, "all"}

      iex> validate_list_scope("agent")
      {:ok, "agent"}
  """
  @spec validate_list_scope(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_list_scope(scope) when scope in @valid_list_scopes, do: {:ok, scope}

  def validate_list_scope(scope) do
    {:error, "Invalid scope '#{scope}'. Use 'local', 'user', 'agent', or 'all'."}
  end

  @doc """
  Enforces agent-level global memory read isolation.

  - If the agent disallows global reads and scope is "user", returns an error.
  - If scope is "all", silently downgrades to "local".
  - Otherwise passes through unchanged.
  """
  def enforce_global_read_isolation("user", %{can_read_global_memories: false}),
    do: {:error, "This agent cannot access global memories. Use scope 'local' instead."}

  def enforce_global_read_isolation("all", %{can_read_global_memories: false}),
    do: {:ok, "local"}

  def enforce_global_read_isolation(scope, _context), do: {:ok, scope}

  @doc """
  Enforces agent-level global memory write isolation.

  If the agent disallows global writes and scope is "user", returns an error.
  Otherwise passes through unchanged.
  """
  def enforce_global_write_isolation("user", %{can_write_global_memories: false}),
    do: {:error, "This agent cannot create or modify global memories. Use scope 'local' instead."}

  def enforce_global_write_isolation(scope, _context), do: {:ok, scope}

  @doc """
  Resolve the user-memory workspace bucket for a tool invocation.

  The conversation is the source of truth: when the tool context carries a
  conversation_id, the bucket is that conversation's workspace (nil for a
  personal conversation), and a bad conversation id is an error rather than
  a silent fall-through to the personal bucket. Without a conversation, a
  workspace_id KEY must be present in the context (a present nil is an
  explicit personal choice).
  """
  @spec resolve_user_bucket(map()) ::
          {:ok, String.t() | nil}
          | {:error, :conversation_not_found}
          | {:error, :no_bucket_context}
  def resolve_user_bucket(ctx) when is_map(ctx) do
    conversation_id = Map.get(ctx, :conversation_id) || Map.get(ctx, "conversation_id")

    cond do
      is_binary(conversation_id) and conversation_id != "" ->
        case Magus.Memory.fetch_workspace_id_for_conversation(conversation_id) do
          {:ok, ws} -> {:ok, ws}
          {:error, :not_found} -> {:error, :conversation_not_found}
        end

      Map.has_key?(ctx, :workspace_id) ->
        {:ok, Map.get(ctx, :workspace_id)}

      Map.has_key?(ctx, "workspace_id") ->
        {:ok, Map.get(ctx, "workspace_id")}

      true ->
        {:error, :no_bucket_context}
    end
  end

  @doc "Human-readable tool error for a failed bucket resolution."
  def bucket_error_message(:conversation_not_found),
    do: "Could not resolve the conversation for this memory operation. Try again."

  def bucket_error_message(:no_bucket_context),
    do: "Missing workspace context for a user-scoped memory operation."
end
