defmodule Magus.Memory.Signals do
  @moduledoc """
  PubSub signal helpers for the memory system.

  Broadcasts real-time updates when memories are created, updated, or deleted.
  The Agents Dashboard subscribes to these events for live updates.
  """

  def memory_created(user_id, memory) do
    broadcast(user_id, %{
      type: "memory_created",
      key: memory.name,
      memory_id: memory.id,
      scope: to_string(memory.scope)
    })
  end

  def memory_updated(user_id, memory) do
    broadcast(user_id, %{
      type: "memory_updated",
      key: memory.name,
      memory_id: memory.id,
      scope: to_string(memory.scope)
    })
  end

  def memory_deleted(user_id, memory) do
    broadcast(user_id, %{
      type: "memory_deleted",
      key: memory.name,
      memory_id: memory.id,
      scope: to_string(memory.scope)
    })
  end

  defp broadcast(user_id, payload) do
    Magus.Endpoint.broadcast(topic(user_id), "memory_signal", payload)
  end

  defp topic(user_id), do: "memory:#{user_id}"
end
