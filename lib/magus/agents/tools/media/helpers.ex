defmodule Magus.Agents.Tools.Media.Helpers do
  @moduledoc false
  # Shared helpers for media generation tools.

  require Ash.Query

  alias Magus.Usage.PolicyEnforcer

  @doc """
  Extracts the user struct from the tool context.
  Falls back to loading from DB if not present.
  """
  def get_user(context) do
    case Magus.Agents.Tools.Helpers.get_context_value(context, :user) do
      %{id: _} = user -> {:ok, user}
      _ -> load_user_fallback(context)
    end
  end

  defp load_user_fallback(context) do
    case Magus.Agents.Tools.Helpers.get_context_value(context, :user_id) do
      nil -> {:error, "No user in context"}
      user_id -> Magus.Accounts.get_user(user_id)
    end
  end

  @doc """
  Loads display-ready refs (`id`, `url`, `type`, `mime_type`) for the given file IDs.
  Used by media tools to surface file info to the LLM so it can embed them in
  drafts (markdown urls) or brain pages (file_ids).
  """
  def load_file_refs([]), do: []

  def load_file_refs(ids) when is_list(ids) do
    case Magus.Files.load_for_display(ids, actor: %Magus.Agents.Support.AiAgent{}) do
      {:ok, files} ->
        Enum.map(files, fn f ->
          %{
            id: f["id"],
            url: f["url"],
            type: f["type"],
            mime_type: f["mime_type"]
          }
        end)

      _ ->
        []
    end
  end

  @doc """
  Fetches a model record from the database by its key.
  """
  def fetch_model_by_key(model_key, actor) do
    case Magus.Chat.Model
         |> Ash.Query.filter(key == ^model_key)
         |> Ash.read_one(actor: actor) do
      {:ok, %{} = model} -> {:ok, model}
      _ -> {:error, "Model not found: #{model_key}"}
    end
  end

  @doc """
  Checks mode access and PAYG spend controls for the user/model pair.
  """
  def check_limits(user, mode, model) do
    with {:ok, :allowed} <- PolicyEnforcer.check_mode_access(user, mode) do
      PolicyEnforcer.check_usage(user, model)
    end
  end

  @doc """
  Finds the most recent image attachment's file_id in a conversation (any source:
  user upload or prior agent generation). Returns nil if none found.
  """
  def last_image_file_id(conversation_id) do
    ai_actor = %Magus.Agents.Support.AiAgent{}

    case Magus.Chat.Message
         |> Ash.Query.filter(conversation_id == ^conversation_id and attachments != [])
         |> Ash.Query.sort(inserted_at: :desc)
         |> Ash.Query.limit(10)
         |> Ash.read(actor: ai_actor) do
      {:ok, messages} ->
        Enum.find_value(messages, fn msg ->
          # :images_by_ids is a read action so it returns {:ok, [file, ...]}.
          case Magus.Files.get_first_image(msg.attachments, actor: ai_actor) do
            {:ok, [%{id: id} | _]} -> id
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  @doc """
  Loads the most recent image from a conversation's message attachments
  as a base64 data URI. Returns nil if no image is found.
  """
  def load_image_from_conversation(conversation_id, actor) do
    case Magus.Chat.Message
         |> Ash.Query.filter(conversation_id == ^conversation_id and attachments != [])
         |> Ash.Query.sort(inserted_at: :desc)
         |> Ash.Query.limit(10)
         |> Ash.read(actor: actor) do
      {:ok, messages} ->
        Enum.find_value(messages, fn msg ->
          case Magus.Files.load_first_image_data_uri(msg.attachments,
                 actor: %Magus.Agents.Support.AiAgent{}
               ) do
            {:ok, data_uri} when is_binary(data_uri) -> data_uri
            _ -> nil
          end
        end)

      _ ->
        nil
    end
  end

  @doc """
  Formats an error reason for user-facing display.
  """
  def format_error(%Magus.Usage.PolicyError{} = err),
    do: Magus.Usage.PolicyErrorMessage.message(err)

  def format_error(reason) when is_binary(reason), do: reason
  def format_error({:unsupported_provider, p}), do: "Unsupported provider: #{p}"
  def format_error(%{message: msg}) when is_binary(msg), do: msg
  def format_error(reason), do: "#{inspect(reason)}"
end
