defmodule Magus.Chat.Conversation.Changes.GenerateName do
  @moduledoc """
  Ash change module that generates conversation titles.

  Delegates to the TitleGenerator agent for the actual LLM interaction.
  """

  use Ash.Resource.Change
  require Ash.Query
  require Logger

  alias Magus.Agents.Actions.GenerateTitle

  @impl true
  def change(changeset, _opts, _context) do
    conversation = changeset.data

    Logger.info(
      "GenerateName: starting for conversation #{conversation.id}, current title: #{inspect(conversation.title)}"
    )

    # Skip if already has a title (user manually renamed it)
    if conversation.title do
      Logger.info("GenerateName: skipping - already has title")
      changeset
    else
      messages = fetch_messages(conversation.id)

      Logger.info("GenerateName: fetched #{length(messages)} messages")

      case GenerateTitle.run(
             %{
               messages: messages,
               user_id: conversation.user_id,
               conversation_id: conversation.id
             },
             %{}
           ) do
        {:ok, %{text: title}} ->
          Logger.info("GenerateName: generated title: #{inspect(title)}")
          Ash.Changeset.force_change_attribute(changeset, :title, title)

        {:error, error} ->
          Logger.error("GenerateName: error: #{inspect(error)}")
          changeset
      end
    end
  end

  defp fetch_messages(conversation_id) do
    Magus.Chat.Message
    |> Ash.Query.filter(conversation_id == ^conversation_id)
    |> Ash.Query.limit(10)
    |> Ash.Query.select([:text, :source])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(actor: %Magus.Agents.Support.AiAgent{})
  end
end
