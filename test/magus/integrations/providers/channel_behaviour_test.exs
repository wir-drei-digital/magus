defmodule Magus.Integrations.Providers.ChannelBehaviourTest do
  use ExUnit.Case, async: true

  defmodule TestChannel do
    @behaviour Magus.Integrations.Providers.ChannelBehaviour
    @behaviour Magus.Integrations.Providers.WebhookChannelBehaviour

    @impl Magus.Integrations.Providers.WebhookChannelBehaviour
    def verify_webhook(_conn, _integration), do: :ok

    @impl Magus.Integrations.Providers.WebhookChannelBehaviour
    def parse_webhook(payload, _headers) do
      {:ok, %{type: :text, external_id: payload["id"], payload: payload}}
    end

    @impl Magus.Integrations.Providers.ChannelBehaviour
    def conversation_identifier(_parsed_input), do: {:ok, "test-id"}

    @impl Magus.Integrations.Providers.ChannelBehaviour
    def default_conversation_mode, do: :single

    @impl Magus.Integrations.Providers.ChannelBehaviour
    def default_async_reply_enabled?, do: false
  end

  test "TestChannel implements ChannelBehaviour required callbacks" do
    assert {:ok, "test-id"} = TestChannel.conversation_identifier(%{})
    assert :single = TestChannel.default_conversation_mode()
    assert false == TestChannel.default_async_reply_enabled?()
  end

  test "TestChannel implements WebhookChannelBehaviour required callbacks" do
    assert :ok = TestChannel.verify_webhook(%{}, %{})
    assert {:ok, %{type: :text}} = TestChannel.parse_webhook(%{"id" => "1"}, [])
  end

  test "default_extract_message_content/1 returns text from common keys" do
    alias Magus.Integrations.Providers.ChannelBehaviour

    assert {:ok, "hello"} = ChannelBehaviour.default_extract_message_content(%{"text" => "hello"})
    assert {:ok, "hello"} = ChannelBehaviour.default_extract_message_content(%{text: "hello"})

    assert {:ok, "hello"} =
             ChannelBehaviour.default_extract_message_content(%{"content" => "hello"})

    assert {:error, :no_content} = ChannelBehaviour.default_extract_message_content(%{})
  end

  test "default_extract_recipient_id/1 returns recipient from common keys" do
    alias Magus.Integrations.Providers.ChannelBehaviour

    assert {:ok, "123"} =
             ChannelBehaviour.default_extract_recipient_id(%{"sender_id" => "123"})

    assert {:ok, "456"} =
             ChannelBehaviour.default_extract_recipient_id(%{chat_id: "456"})

    assert {:ok, nil} = ChannelBehaviour.default_extract_recipient_id(%{})
  end
end
