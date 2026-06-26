defmodule Magus.Integrations.Providers.Telegram.Api do
  @moduledoc """
  Thin HTTP wrapper for the Telegram Bot API.

  All functions accept a bot token as the first argument and make requests
  to `https://api.telegram.org/bot<token>/<method>`.
  """

  require Logger

  @base_url "https://api.telegram.org"
  @max_message_length 4096

  @doc """
  Validate the bot token and return bot info.
  """
  def get_me(token) do
    post(token, "getMe", %{})
  end

  @doc """
  Send a text message to a chat.

  Automatically splits messages longer than 4096 characters.
  """
  def send_message(token, chat_id, text, opts \\ []) do
    if byte_size(text) > @max_message_length do
      send_long_message(token, chat_id, text, opts)
    else
      params =
        %{chat_id: chat_id, text: text}
        |> maybe_put(:parse_mode, opts[:parse_mode])
        |> maybe_put(:reply_to_message_id, opts[:reply_to_message_id])

      post(token, "sendMessage", params)
    end
  end

  @doc """
  Send a photo to a chat.

  `photo` can be:
  - A URL string (Telegram will download it)
  - A file_id string (previously uploaded to Telegram)
  - `{:binary, data, filename}` tuple for uploading binary data via multipart
  """
  def send_photo(token, chat_id, photo, opts \\ [])

  def send_photo(token, chat_id, {:binary, data, filename}, opts) do
    multipart_upload(token, "sendPhoto", chat_id, "photo", data, filename, opts)
  end

  def send_photo(token, chat_id, photo, opts) do
    params =
      %{chat_id: chat_id, photo: photo}
      |> maybe_put(:caption, opts[:caption])
      |> maybe_put(:parse_mode, opts[:parse_mode])

    post(token, "sendPhoto", params)
  end

  @doc """
  Register a webhook URL with Telegram.
  """
  def set_webhook(token, url, opts \\ []) do
    params =
      %{url: url}
      |> maybe_put(:secret_token, opts[:secret_token])
      |> maybe_put(:max_connections, opts[:max_connections])
      |> maybe_put(:allowed_updates, opts[:allowed_updates])

    post(token, "setWebhook", params)
  end

  @doc """
  Remove the webhook.
  """
  def delete_webhook(token) do
    post(token, "deleteWebhook", %{})
  end

  @doc """
  Send a chat action (e.g. "typing") to indicate the bot is processing.

  The action auto-expires after ~5 seconds on the client side.
  """
  def send_chat_action(token, chat_id, action \\ "typing") do
    post(token, "sendChatAction", %{chat_id: chat_id, action: action})
  end

  @doc """
  Get file info by file_id (for downloading media).
  """
  def get_file(token, file_id) do
    post(token, "getFile", %{file_id: file_id})
  end

  # ===========================================================================
  # Internal
  # ===========================================================================

  defp post(token, method, params) do
    url = "#{@base_url}/bot#{token}/#{method}"

    case Req.post(url, json: params, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}} ->
        {:ok, result}

      {:ok, %{status: status, body: %{"ok" => false, "description" => desc}}} ->
        Logger.warning("Telegram API error (#{status}): #{desc}")
        {:error, {:telegram_error, status, desc}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Telegram API unexpected response (#{status}): #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, reason} ->
        Logger.error("Telegram API request failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp send_long_message(token, chat_id, text, opts) do
    chunks = split_text(text, @max_message_length)

    Enum.reduce_while(chunks, {:ok, nil}, fn chunk, _acc ->
      case send_message(token, chat_id, chunk, opts) do
        {:ok, result} -> {:cont, {:ok, result}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp split_text(text, max_length) do
    # Split on paragraph boundaries to avoid breaking mid-sentence
    text
    |> String.split("\n\n")
    |> Enum.reduce([""], fn paragraph, [current | rest] ->
      candidate = if current == "", do: paragraph, else: current <> "\n\n" <> paragraph

      if byte_size(candidate) > max_length do
        # Start a new chunk
        [paragraph, current | rest]
      else
        [candidate | rest]
      end
    end)
    |> Enum.reverse()
    |> Enum.reject(&(&1 == ""))
  end

  defp multipart_upload(token, method, chat_id, field_name, data, filename, opts) do
    url = "#{@base_url}/bot#{token}/#{method}"

    content_type = mime_type_from_filename(filename)

    multipart =
      {
        :multipart,
        [
          {"chat_id", to_string(chat_id)},
          {field_name, data, {"form-data", [name: field_name, filename: filename]},
           [{"content-type", content_type}]}
        ]
        |> maybe_add_part("caption", opts[:caption])
        |> maybe_add_part("parse_mode", opts[:parse_mode])
      }

    case Req.post(url, body: multipart, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"ok" => true, "result" => result}}} ->
        {:ok, result}

      {:ok, %{status: status, body: %{"ok" => false, "description" => desc}}} ->
        Logger.warning("Telegram API error (#{status}): #{desc}")
        {:error, {:telegram_error, status, desc}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Telegram API unexpected response (#{status}): #{inspect(body)}")
        {:error, {:unexpected_response, status}}

      {:error, reason} ->
        Logger.error("Telegram API multipart upload failed: #{inspect(reason)}")
        {:error, {:request_failed, reason}}
    end
  end

  defp maybe_add_part(parts, _name, nil), do: parts
  defp maybe_add_part(parts, name, value), do: parts ++ [{name, to_string(value)}]

  defp mime_type_from_filename(filename) do
    case Path.extname(filename) |> String.downcase() do
      ".jpg" -> "image/jpeg"
      ".jpeg" -> "image/jpeg"
      ".png" -> "image/png"
      ".gif" -> "image/gif"
      ".webp" -> "image/webp"
      _ -> "application/octet-stream"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
