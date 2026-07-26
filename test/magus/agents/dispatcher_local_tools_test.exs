defmodule Magus.Agents.DispatcherLocalToolsTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Dispatcher
  alias Magus.Chat.{Conversation, Message}

  defp message(metadata) do
    %Message{
      id: Ecto.UUID.generate(),
      text: "hi",
      mode: :chat,
      selected_model_id: nil,
      attachments: [],
      metadata: metadata
    }
  end

  defp conversation, do: %Conversation{chat_mode: :chat}
  defp routed, do: %{routing_reason: nil, model_keys: %{}}

  test "threads caller_session_id and local_tools from metadata into signal data" do
    data =
      Dispatcher.build_signal_data(
        message(%{"caller_session_id" => "s1", "local_tools" => ["read_file"]}),
        conversation(),
        routed()
      )

    assert data[:caller_session_id] == "s1"
    assert data[:local_tools] == ["read_file"]
  end

  test "omits the local-tool keys when metadata has none" do
    data = Dispatcher.build_signal_data(message(%{}), conversation(), routed())
    refute Map.has_key?(data, :caller_session_id)
    refute Map.has_key?(data, :local_tools)
  end
end
