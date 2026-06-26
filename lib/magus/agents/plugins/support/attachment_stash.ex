defmodule Magus.Agents.Plugins.Support.AttachmentStash do
  @moduledoc """
  Per-turn attachment accumulator shared between plugins inside one agent
  GenServer.

  Media tools (generate_image, generate_video) return file IDs under a
  well-known `:__attachments__` key. `ToolEventPlugin` pops them and calls
  `put/1`; `PersistencePlugin` calls `drain/0` when persisting the assistant
  response so the files land on the message's `attachments` field. A failed
  turn calls `clear/0` so a later turn doesn't inherit stale IDs.

  Stored in the process dictionary of the agent GenServer; never crosses
  processes or conversations.
  """

  @key :__response_attachments__

  @spec put([String.t()]) :: :ok
  def put([]), do: :ok

  def put(ids) when is_list(ids) do
    current = Process.get(@key, [])
    Process.put(@key, current ++ ids)
    :ok
  end

  @spec drain() :: [String.t()]
  def drain do
    case Process.delete(@key) do
      ids when is_list(ids) -> Enum.uniq(ids)
      _ -> []
    end
  end

  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end
end
