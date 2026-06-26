defmodule Magus.Brain.Changes.BroadcastBrainEvent do
  @moduledoc """
  Broadcasts PubSub events after brain resource changes.

  Fires on brain-level and page-level topics with actor_id for
  self-update filtering. Eagerly resolves brain_id before the action
  to avoid extra DB queries in after_transaction.
  """
  use Ash.Resource.Change

  alias Magus.Brain.Topics

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def change(changeset, opts, context) do
    resource_type = opts[:resource_type] || :unknown
    actor_id = extract_actor_id(context)
    source = Process.get(:brain_edit_source)
    action_name = changeset.action.name

    # Broadcasts are advisory: subscribers re-query the DB on receipt, so if
    # the outer transaction rolls back they just see no row. Silence Ash's
    # warning about after_transaction hooks running inside a surrounding
    # transaction.
    changeset = Ash.Changeset.set_context(changeset, %{warn_on_transaction_hooks?: false})

    event_type =
      cond do
        resource_type == :page and action_name == :update_body ->
          "page.body_updated"

        true ->
          case changeset.action.type do
            :create -> "#{resource_type}.created"
            :update -> "#{resource_type}.updated"
            :destroy -> "#{resource_type}.deleted"
            _ -> "#{resource_type}.changed"
          end
      end

    eager_brain_id =
      if changeset.action.type in [:update, :destroy] do
        resolve_brain_id_from_data(changeset.data, resource_type)
      end

    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      record =
        case result do
          {:ok, rec} -> rec
          :ok -> changeset.data
          _ -> nil
        end

      if record do
        brain_id = eager_brain_id || resolve_brain_id(record, resource_type)
        broadcast(event_type, record, brain_id, actor_id, source)
      end

      result
    end)
  end

  defp broadcast(_event_type, _record, nil, _actor_id, _source), do: :ok

  defp broadcast("page.body_updated", record, brain_id, actor_id, source) do
    payload = %{
      record: record,
      brain_id: brain_id,
      body: record.body,
      lock_version: record.lock_version,
      modified_at: record.updated_at,
      actor_id: actor_id,
      source: source || :user
    }

    Magus.Endpoint.broadcast(Topics.brain(brain_id), "page.body_updated", payload)
    Magus.Endpoint.broadcast(Topics.page(brain_id, record.id), "page.body_updated", payload)
    :ok
  end

  defp broadcast(event_type, record, brain_id, actor_id, source) do
    payload = %{record: record, brain_id: brain_id, actor_id: actor_id, source: source}
    Magus.Endpoint.broadcast(Topics.brain(brain_id), event_type, payload)
    :ok
  end

  defp extract_actor_id(%{actor: %{id: id}}), do: id
  defp extract_actor_id(_), do: nil

  defp resolve_brain_id_from_data(data, :brain), do: data.id
  defp resolve_brain_id_from_data(data, :page), do: data.brain_id

  defp resolve_brain_id(record, :brain), do: record.id
  defp resolve_brain_id(record, :page), do: record.brain_id
end
