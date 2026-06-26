defmodule Magus.Chat.ContextWindow.Operations do
  @moduledoc """
  Shared, conversation-keyed context-window operations used by both the
  LiveView donut controls and the SvelteKit SPA (via the generic RPC actions on
  `Magus.Chat.ContextWindow`).

  Each function get-or-creates the per-conversation window row (owner-gated by
  the `ConversationOwner` check), performs the operation (owner-gated by the
  underlying action policy), broadcasts a `context.updated` signal so other open
  tabs/devices refetch, and returns the updated row. All calls pass the supplied
  `actor` through, so authorization is enforced by the resource policies.

  The "clear to latest message" pointer logic lives here (`latest_message_pointer/2`)
  so the LiveView and the RPC surface share one implementation.
  """
  require Ash.Query

  alias Magus.Agents.Signals

  @doc """
  Get-or-create the window for `conversation_id`, advance the floor past the
  latest message (so the next window is empty), drop the summary, broadcast,
  and return the updated row.
  """
  @spec clear(Ecto.UUID.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def clear(conversation_id, opts) do
    with {:ok, cw} <- Magus.Chat.get_or_create_context_window(conversation_id, opts),
         {start_id, start_at} <- latest_message_pointer(conversation_id, actor(opts)),
         {:ok, cleared} <-
           Magus.Chat.clear_context_window(
             cw,
             %{window_start_message_id: start_id, window_start_at: start_at},
             opts
           ) do
      broadcast(conversation_id)
      {:ok, cleared}
    end
  end

  @doc """
  Get-or-create the window for `conversation_id`, request a compaction pass
  (transition to `:pending` + enqueue the Oban trigger), broadcast, and return
  the updated row.
  """
  @spec compact(Ecto.UUID.t(), keyword()) :: {:ok, struct()} | {:error, term()}
  def compact(conversation_id, opts) do
    with {:ok, cw} <- Magus.Chat.get_or_create_context_window(conversation_id, opts),
         {:ok, requested} <- Magus.Chat.request_context_compaction(cw, %{}, opts) do
      broadcast(conversation_id)
      {:ok, requested}
    end
  end

  @doc """
  Get-or-create the window for `conversation_id`, set the per-conversation
  strategy override, broadcast, and return the updated row.
  """
  @spec set_strategy(Ecto.UUID.t(), atom() | nil, keyword()) ::
          {:ok, struct()} | {:error, term()}
  def set_strategy(conversation_id, strategy, opts) do
    with {:ok, cw} <- Magus.Chat.get_or_create_context_window(conversation_id, opts),
         {:ok, updated} <-
           Magus.Chat.set_context_strategy(cw, %{strategy: strategy}, opts) do
      broadcast(conversation_id)
      {:ok, updated}
    end
  end

  @doc """
  Pointer for a context-window clear: the window floor is set to just AFTER the
  most recent message so the next window is empty (the history filter is
  inclusive `>=`, so the floor must be strictly past the latest message to
  exclude it). `window_start_message_id` keeps the latest message's id for
  reference. Returns `{message_id, window_start_at}`. With no messages the
  window simply starts now and nothing precedes it.
  """
  @spec latest_message_pointer(Ecto.UUID.t(), term()) ::
          {Ecto.UUID.t() | nil, DateTime.t()}
  def latest_message_pointer(conversation_id, actor) do
    Magus.Chat.Message
    |> Ash.Query.for_read(:for_conversation, %{conversation_id: conversation_id}, actor: actor)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!()
    |> case do
      [msg | _] -> {msg.id, DateTime.add(msg.inserted_at, 1, :microsecond)}
      [] -> {nil, DateTime.utc_now() |> DateTime.truncate(:microsecond)}
    end
  end

  # Nudge other open tabs/devices to refetch the snapshot.
  defp broadcast(conversation_id), do: Signals.context_updated(conversation_id, %{})

  defp actor(opts), do: Keyword.get(opts, :actor)
end
