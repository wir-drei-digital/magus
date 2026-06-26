defmodule Magus.Chat.Message.Relationships.AttachmentResources do
  @moduledoc """
  Manual relationship that loads Memory.Resource records from the message's
  attachments array (list of UUIDs).
  """
  use Ash.Resource.ManualRelationship

  require Ash.Query

  @impl true
  def load(messages, _opts, %{query: query}) do
    # Collect all attachment IDs from all messages
    all_ids =
      messages
      |> Enum.flat_map(fn message ->
        message.attachments || []
      end)
      |> Enum.uniq()

    if all_ids == [] do
      {:ok, Map.new(messages, fn message -> {message.id, []} end)}
    else
      # Load all resources in one query
      resources =
        query
        |> Ash.Query.filter(id in ^all_ids)
        |> Ash.read!()
        |> Map.new(fn r -> {r.id, r} end)

      # Map each message to its resources (preserving order)
      result =
        Map.new(messages, fn message ->
          message_resources =
            (message.attachments || [])
            |> Enum.map(fn id -> Map.get(resources, id) end)
            |> Enum.reject(&is_nil/1)

          {message.id, message_resources}
        end)

      {:ok, result}
    end
  end
end
