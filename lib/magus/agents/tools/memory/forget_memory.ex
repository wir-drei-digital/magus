defmodule Magus.Agents.Tools.Memory.ForgetMemory do
  @moduledoc """
  Tool for permanently deleting a memory by exact name.

  When a user explicitly asks the model to forget something, this tool
  allows the model to immediately and permanently delete that memory.
  """

  use Jido.Action,
    name: "forget_memory",
    description: """
    Permanently delete a memory by its exact name. This cannot be undone. Use this when the user explicitly asks you to forget something.

    SCOPE determines where to look, mirroring where you would have saved it:
    - "local" (default): Anything about this conversation or project.
    - "user": Durable, user-wide memories available everywhere.

    The memory name must match exactly. If you're unsure of the name, use search_memories first to find it.
    """,
    schema: [
      name: [
        type: :string,
        required: true,
        doc: "Exact name of the memory to forget"
      ],
      scope: [
        type: :string,
        required: false,
        default: "local",
        doc: "Memory scope: 'local' (default) or 'user'"
      ]
    ]

  require Logger

  alias Magus.Memory

  import Magus.Agents.Tools.Memory.Helpers,
    only: [
      validate_context: 2,
      validate_scope: 1,
      find_memory_by_name: 3,
      ai_actor: 0,
      enforce_global_read_isolation: 2,
      enforce_global_write_isolation: 2,
      resolve_user_bucket: 1,
      bucket_error_message: 1
    ]

  import Magus.Agents.Tools.Helpers, only: [get_param: 2, get_param: 3]

  def display_name, do: "Forgetting memory..."

  def summarize_output(%{status: "forgotten", name: name}), do: "Forgot '#{name}'"
  def summarize_output(%{status: "not_found"}), do: "Not found"
  def summarize_output(%{error: _}), do: "Error"
  def summarize_output(_), do: "Completed"

  @impl true
  def run(params, context) do
    scope = get_param(params, :scope, "local")

    with {:ok, scope} <- validate_scope(scope),
         {:ok, scope} <- enforce_global_read_isolation(scope, context),
         {:ok, scope} <- enforce_global_write_isolation(scope, context) do
      required_fields =
        case scope do
          "user" -> [:user_id]
          _ -> [:user_id, :conversation_id]
        end

      with {:ok, ctx} <- validate_context(context, required_fields),
           {:ok, ctx} <- put_user_bucket(ctx, context, scope) do
        name = get_param(params, :name)
        forget_memory(name, scope, ctx)
      else
        {:error, message} -> {:ok, %{error: message}}
      end
    else
      {:error, message} -> {:ok, %{error: message}}
    end
  end

  # For user scope, resolve the workspace bucket from the conversation (the
  # tool context value is only a fallback) and pin it into ctx so the lookup
  # uses the same bucket. Resolution reads from the original tool context,
  # since validate_context/2 strips ctx down to only the scope's
  # required_fields.
  defp put_user_bucket(ctx, context, "user") do
    case resolve_user_bucket(context) do
      {:ok, workspace_id} -> {:ok, Map.put(ctx, :workspace_id, workspace_id)}
      {:error, reason} -> {:error, bucket_error_message(reason)}
    end
  end

  defp put_user_bucket(ctx, _context, _scope), do: {:ok, ctx}

  defp forget_memory(name, scope, ctx) do
    case find_memory_by_name(name, scope, ctx) do
      {:ok, memory} ->
        case Memory.destroy_memory(memory, actor: ai_actor()) do
          :ok ->
            Logger.debug("ForgetMemory: destroyed '#{name}' (#{scope})")
            {:ok, %{status: "forgotten", name: name, scope: scope}}

          {:error, error} ->
            Logger.warning("ForgetMemory: destroy failed - #{inspect(error)}")
            {:ok, %{error: "Failed to forget memory: #{inspect(error)}"}}
        end

      {:error, :not_found} ->
        {:ok,
         %{
           status: "not_found",
           name: name,
           scope: scope,
           hint:
             "No memory named '#{name}' found in #{scope} scope. Use search_memories to find the correct name."
         }}

      {:error, error} ->
        Logger.warning("ForgetMemory: lookup failed - #{inspect(error)}")
        {:ok, %{error: "Failed to look up memory: #{inspect(error)}"}}
    end
  end
end
