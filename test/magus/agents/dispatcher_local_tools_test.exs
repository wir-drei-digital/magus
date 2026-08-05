defmodule Magus.Agents.DispatcherLocalToolsTest do
  use ExUnit.Case, async: true

  alias Magus.Agents.Dispatcher
  alias Magus.Chat.{Conversation, Message}

  defp message(metadata, created_by_id \\ Ecto.UUID.generate()) do
    %Message{
      id: Ecto.UUID.generate(),
      text: "hi",
      mode: :chat,
      selected_model_id: nil,
      attachments: [],
      metadata: metadata,
      created_by_id: created_by_id
    }
  end

  defp conversation, do: %Conversation{chat_mode: :chat}
  defp routed, do: %{routing_reason: nil, model_keys: %{}}

  test "threads local_tools from metadata into signal data" do
    data =
      Dispatcher.build_signal_data(
        message(%{"local_tools" => ["read_file"]}),
        conversation(),
        routed()
      )

    assert data[:local_tools] == ["read_file"]
  end

  test "omits the local-tools key when metadata has none or an empty list" do
    for metadata <- [%{}, %{"local_tools" => []}] do
      data = Dispatcher.build_signal_data(message(metadata), conversation(), routed())
      refute Map.has_key?(data, :local_tools)
    end
  end

  test "drops non-string entries and never threads a caller_session_id (routing is server-side)" do
    data =
      Dispatcher.build_signal_data(
        message(%{
          # metadata is client-writable over RPC — a forged routing identity
          # must not survive into the signal data
          "caller_session_id" => "victim-user:victim-session",
          "local_tools" => ["read_file", 42, %{"evil" => true}]
        }),
        conversation(),
        routed()
      )

    refute Map.has_key?(data, :caller_session_id)
    assert data[:local_tools] == ["read_file"]
  end

  test "drops local_tools on an unattributed message (nil created_by_id)" do
    # Dispatchable messages without relate_actor (e.g. job triggers) resolve
    # acting_user_id to the conversation OWNER in Preflight; they must never
    # carry reverse-tunnel tools under that borrowed identity.
    data =
      Dispatcher.build_signal_data(
        message(%{"local_tools" => ["read_file"]}, nil),
        conversation(),
        routed()
      )

    refute Map.has_key?(data, :local_tools)
  end
end
