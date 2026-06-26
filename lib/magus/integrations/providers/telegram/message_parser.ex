defmodule Magus.Integrations.Providers.Telegram.MessageParser do
  @moduledoc """
  Parses Telegram Update JSON into the normalized format expected by `ProcessWebhook`.
  """

  @doc """
  Parse a Telegram Update payload into a normalized message map.

  Returns `{:ok, parsed}` or `{:error, reason}`.
  """
  def parse(%{"callback_query" => callback}) when is_map(callback) do
    from = callback["from"] || %{}

    {:ok,
     %{
       type: :callback,
       external_id: to_string(callback["id"]),
       text: callback["data"],
       content: callback["data"],
       sender_id: to_string(from["id"]),
       sender_name: build_name(from),
       sender_username: from["username"],
       chat_id: get_in(callback, ["message", "chat", "id"]),
       metadata: %{
         callback_query_id: callback["id"],
         message_id: get_in(callback, ["message", "message_id"]),
         data: callback["data"]
       }
     }}
  end

  def parse(%{"message" => message}) when is_map(message) do
    parse_message(message)
  end

  def parse(%{"edited_message" => message}) when is_map(message) do
    parse_message(message)
  end

  def parse(%{"channel_post" => message}) when is_map(message) do
    parse_message(message)
  end

  def parse(_payload) do
    {:error, :unsupported_update_type}
  end

  # ===========================================================================
  # Private
  # ===========================================================================

  defp parse_message(message) do
    chat = message["chat"] || %{}
    from = message["from"] || chat
    chat_id = chat["id"]

    {type, text, metadata} = extract_content(message)

    {:ok,
     %{
       type: type,
       external_id: to_string(message["message_id"]),
       text: text,
       content: text,
       sender_id: to_string(chat_id),
       sender_name: build_name(from),
       sender_username: from["username"],
       chat_id: chat_id,
       metadata: metadata
     }}
  end

  defp extract_content(%{"photo" => [_ | _] = photos} = msg) do
    # Telegram sends multiple sizes; pick the largest (last)
    largest = List.last(photos)

    {:image, msg["caption"] || "",
     %{
       file_id: largest["file_id"],
       file_unique_id: largest["file_unique_id"],
       width: largest["width"],
       height: largest["height"]
     }}
  end

  defp extract_content(%{"document" => doc} = msg) do
    {:file, msg["caption"] || "",
     %{
       file_id: doc["file_id"],
       file_name: doc["file_name"],
       mime_type: doc["mime_type"],
       file_size: doc["file_size"]
     }}
  end

  defp extract_content(%{"audio" => audio} = msg) do
    {:audio, msg["caption"] || "",
     %{
       file_id: audio["file_id"],
       duration: audio["duration"],
       title: audio["title"],
       performer: audio["performer"]
     }}
  end

  defp extract_content(%{"voice" => voice} = _msg) do
    {:audio, "",
     %{
       file_id: voice["file_id"],
       duration: voice["duration"]
     }}
  end

  defp extract_content(%{"video" => video} = msg) do
    {:video, msg["caption"] || "",
     %{
       file_id: video["file_id"],
       duration: video["duration"],
       width: video["width"],
       height: video["height"]
     }}
  end

  defp extract_content(%{"sticker" => sticker} = _msg) do
    {:image, sticker["emoji"] || "",
     %{
       file_id: sticker["file_id"],
       is_sticker: true,
       set_name: sticker["set_name"]
     }}
  end

  defp extract_content(%{"location" => location} = _msg) do
    {:event, "Location shared",
     %{
       latitude: location["latitude"],
       longitude: location["longitude"]
     }}
  end

  defp extract_content(%{"text" => text}) do
    {:text, text, %{}}
  end

  defp extract_content(_msg) do
    {:text, "[Unsupported message type]", %{}}
  end

  defp build_name(%{"first_name" => first} = from) do
    case from["last_name"] do
      nil -> first
      last -> "#{first} #{last}"
    end
  end

  defp build_name(_), do: nil
end
