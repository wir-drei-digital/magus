defmodule Magus.IntegrationsTest do
  @moduledoc """
  Comprehensive tests for the Integrations domain.
  """
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Integrations

  defp create_agent(user) do
    {:ok, agent} =
      Magus.Agents.create_custom_agent(%{name: "Test Agent"}, actor: user)

    agent
  end

  describe "provider registry" do
    test "get_provider_module returns module for known key" do
      assert Integrations.get_provider_module(:telegram) ==
               Magus.Integrations.Providers.Telegram
    end

    test "get_provider_module returns nil for unknown key" do
      assert Integrations.get_provider_module(:non_existent) == nil
    end

    test "list_provider_modules returns all registered providers" do
      modules = Integrations.list_provider_modules()
      assert is_map(modules)
      assert Map.has_key?(modules, :telegram)
      assert Map.has_key?(modules, :simple_webhook)
    end

    test "list_available_providers returns provider metadata" do
      providers = Integrations.list_available_providers()
      assert is_list(providers)
      assert length(providers) > 0

      telegram = Enum.find(providers, &(&1.key == :telegram))
      assert telegram != nil
      assert telegram.name == Magus.Integrations.Providers.Telegram.name()
      assert telegram.auth_type == Magus.Integrations.Providers.Telegram.auth_type()
    end
  end

  describe "user_integrations" do
    setup do
      user = generate(user())
      agent = create_agent(user)

      %{user: user, agent: agent}
    end

    test "can create user integration", %{user: user, agent: agent} do
      assert {:ok, integration} =
               Integrations.create_user_integration(
                 :simple_webhook,
                 %{user_id: user.id, custom_agent_id: agent.id, config: %{some: "config"}},
                 actor: user
               )

      assert integration.user_id == user.id
      assert integration.custom_agent_id == agent.id
      assert integration.status == :pending
      assert integration.config == %{"some" => "config"}
      assert integration.provider_key == :simple_webhook
    end

    test "conversation_mode defaults to single", %{user: user, agent: agent} do
      {:ok, integration} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      assert integration.conversation_mode == :single
    end

    test "async_reply_enabled defaults to true", %{user: user, agent: agent} do
      {:ok, integration} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      assert integration.async_reply_enabled == true
    end

    test "can activate integration", %{user: user, agent: agent} do
      {:ok, integration} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      {:ok, activated} = Integrations.activate_user_integration(integration, actor: user)
      assert activated.status == :active
    end

    test "can update config with conversation_mode", %{user: user, agent: agent} do
      {:ok, integration} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      {:ok, updated} =
        Integrations.update_integration_config(
          integration,
          %{conversation_mode: :multi, async_reply_enabled: false},
          actor: user
        )

      assert updated.conversation_mode == :multi
      assert updated.async_reply_enabled == false
    end

    test "can list by user and provider", %{user: user, agent: agent} do
      {:ok, _} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      {:ok, integrations} =
        Integrations.list_user_integrations_by_provider(user.id, :simple_webhook, actor: user)

      assert length(integrations) == 1
      assert hd(integrations).user_id == user.id
    end

    test "enforces unique agent + provider", %{user: user, agent: agent} do
      {:ok, _} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      assert {:error, _} =
               Integrations.create_user_integration(
                 :simple_webhook,
                 %{user_id: user.id, custom_agent_id: agent.id},
                 actor: user
               )
    end
  end

  describe "multi-integration support (custom_api)" do
    setup do
      user = generate(user())
      agent = create_agent(user)

      %{user: user, agent: agent}
    end

    test "multiple :custom_api integrations on same agent are allowed", %{
      user: user,
      agent: agent
    } do
      assert {:ok, integration1} =
               Integrations.create_user_integration(
                 :custom_api,
                 %{user_id: user.id, custom_agent_id: agent.id, config: %{name: "Jira"}},
                 actor: user
               )

      assert {:ok, integration2} =
               Integrations.create_user_integration(
                 :custom_api,
                 %{user_id: user.id, custom_agent_id: agent.id, config: %{name: "GitHub"}},
                 actor: user
               )

      assert integration1.id != integration2.id
      assert integration1.provider_key == :custom_api
      assert integration2.provider_key == :custom_api
    end

    test "list_by_agent_and_provider returns all custom_api integrations for an agent", %{
      user: user,
      agent: agent
    } do
      {:ok, _} =
        Integrations.create_user_integration(
          :custom_api,
          %{user_id: user.id, custom_agent_id: agent.id, config: %{name: "Jira"}},
          actor: user
        )

      {:ok, _} =
        Integrations.create_user_integration(
          :custom_api,
          %{user_id: user.id, custom_agent_id: agent.id, config: %{name: "GitHub"}},
          actor: user
        )

      {:ok, integrations} =
        Integrations.list_by_agent_and_provider(agent.id, :custom_api, actor: user)

      assert length(integrations) == 2
      assert Enum.all?(integrations, &(&1.provider_key == :custom_api))
      assert Enum.all?(integrations, &(&1.custom_agent_id == agent.id))
    end

    test "non-custom_api providers still enforce uniqueness", %{user: user, agent: agent} do
      assert {:ok, _} =
               Integrations.create_user_integration(
                 :telegram,
                 %{user_id: user.id, custom_agent_id: agent.id},
                 actor: user
               )

      assert {:error, _} =
               Integrations.create_user_integration(
                 :telegram,
                 %{user_id: user.id, custom_agent_id: agent.id},
                 actor: user
               )
    end
  end

  describe "input_messages" do
    setup do
      user = generate(user())
      agent = create_agent(user)

      {:ok, integration} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      %{user: user, integration: integration}
    end

    test "can create input message", %{user: user, integration: integration} do
      {:ok, msg} =
        Integrations.create_input_message(
          %{
            user_id: user.id,
            provider_key: :simple_webhook,
            message_type: :text,
            payload: %{"text" => "Hello from webhook"},
            user_integration_id: integration.id
          },
          authorize?: false
        )

      assert msg.status == :pending
      assert msg.provider_key == :simple_webhook
      assert msg.payload["text"] == "Hello from webhook"
    end

    test "can mark as processed", %{user: user, integration: integration} do
      {:ok, msg} =
        Integrations.create_input_message(
          %{
            user_id: user.id,
            provider_key: :simple_webhook,
            message_type: :text,
            payload: %{},
            user_integration_id: integration.id
          },
          authorize?: false
        )

      {:ok, processed} = Integrations.mark_input_processed(msg, authorize?: false)
      assert processed.status == :processed
      assert processed.processed_at != nil
    end

    test "can mark as failed", %{user: user, integration: integration} do
      {:ok, msg} =
        Integrations.create_input_message(
          %{
            user_id: user.id,
            provider_key: :simple_webhook,
            message_type: :text,
            payload: %{},
            user_integration_id: integration.id
          },
          authorize?: false
        )

      {:ok, failed} =
        Integrations.mark_input_failed(msg, %{error_message: "Test error"}, authorize?: false)

      assert failed.status == :failed
      assert failed.error_message == "Test error"
    end

    test "can list pending messages", %{user: user, integration: integration} do
      # Create pending message
      {:ok, _} =
        Integrations.create_input_message(
          %{
            user_id: user.id,
            provider_key: :simple_webhook,
            message_type: :text,
            payload: %{},
            user_integration_id: integration.id
          },
          authorize?: false
        )

      {:ok, page} = Integrations.list_pending_input_messages(authorize?: false)
      assert length(page.results) >= 1
    end

    test "deduplicates by external_id", %{user: user, integration: integration} do
      attrs = %{
        user_id: user.id,
        provider_key: :simple_webhook,
        external_id: "unique-msg-123",
        message_type: :text,
        payload: %{},
        user_integration_id: integration.id
      }

      {:ok, _} = Integrations.create_input_message(attrs, authorize?: false)
      assert {:error, _} = Integrations.create_input_message(attrs, authorize?: false)
    end
  end

  describe "output_messages" do
    setup do
      user = generate(user())
      agent = create_agent(user)

      {:ok, integration} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      %{user: user, integration: integration}
    end

    test "can create output message", %{user: user, integration: integration} do
      {:ok, msg} =
        Integrations.create_output_message(
          %{
            user_id: user.id,
            provider_key: :simple_webhook,
            operation: :send_message,
            payload: %{"text" => "Hello!"},
            user_integration_id: integration.id
          },
          authorize?: false
        )

      assert msg.status == :pending
      assert msg.operation == :send_message
    end

    test "can mark as sent", %{user: user, integration: integration} do
      {:ok, msg} =
        Integrations.create_output_message(
          %{
            user_id: user.id,
            provider_key: :simple_webhook,
            operation: :send_message,
            payload: %{},
            user_integration_id: integration.id
          },
          authorize?: false
        )

      {:ok, sent} =
        Integrations.mark_output_sent(msg, %{external_id: "sent-123"}, authorize?: false)

      assert sent.status == :sent
      assert sent.sent_at != nil
      assert sent.external_id == "sent-123"
    end

    test "can mark as failed and increment retry", %{user: user, integration: integration} do
      {:ok, msg} =
        Integrations.create_output_message(
          %{
            user_id: user.id,
            provider_key: :simple_webhook,
            operation: :send_message,
            payload: %{},
            user_integration_id: integration.id
          },
          authorize?: false
        )

      {:ok, failed} =
        Integrations.mark_output_failed(msg, %{error_message: "API error"}, authorize?: false)

      assert failed.status == :failed
      assert failed.retry_count == 1
    end
  end

  describe "integration_conversations (multi-mode)" do
    setup do
      user = generate(user())
      agent = create_agent(user)

      {:ok, integration} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id, conversation_mode: :multi},
          actor: user
        )

      # Create a conversation
      {:ok, conversation} =
        Magus.Chat.create_conversation(
          %{title: "Test Conversation", chat_mode: :chat},
          actor: user
        )

      %{user: user, integration: integration, conversation: conversation}
    end

    test "can create integration conversation mapping", %{
      integration: integration,
      conversation: conversation
    } do
      {:ok, mapping} =
        Integrations.create_integration_conversation(
          %{
            user_integration_id: integration.id,
            conversation_id: conversation.id,
            external_identifier: "discord-user-123"
          },
          authorize?: false
        )

      assert mapping.external_identifier == "discord-user-123"
      assert mapping.conversation_id == conversation.id
    end

    test "can look up by identifier", %{integration: integration, conversation: conversation} do
      {:ok, _} =
        Integrations.create_integration_conversation(
          %{
            user_integration_id: integration.id,
            conversation_id: conversation.id,
            external_identifier: "lookup-test-123"
          },
          authorize?: false
        )

      {:ok, found} =
        Integrations.get_integration_conversation_by_identifier(
          integration.id,
          "lookup-test-123",
          authorize?: false
        )

      assert found.conversation_id == conversation.id
    end

    test "enforces unique identifier per integration", %{
      user: user,
      integration: integration,
      conversation: conversation
    } do
      # Create second conversation
      {:ok, conv2} =
        Magus.Chat.create_conversation(
          %{title: "Second Conversation", chat_mode: :chat},
          actor: user
        )

      {:ok, _} =
        Integrations.create_integration_conversation(
          %{
            user_integration_id: integration.id,
            conversation_id: conversation.id,
            external_identifier: "unique-id-test"
          },
          authorize?: false
        )

      # Should fail with same identifier
      assert {:error, _} =
               Integrations.create_integration_conversation(
                 %{
                   user_integration_id: integration.id,
                   conversation_id: conv2.id,
                   external_identifier: "unique-id-test"
                 },
                 authorize?: false
               )
    end
  end

  describe "reactivate_if_errored/2" do
    setup do
      user = generate(user())
      agent = create_agent(user)

      {:ok, integration} =
        Integrations.create_user_integration(
          :simple_webhook,
          %{user_id: user.id, custom_agent_id: agent.id},
          actor: user
        )

      %{user: user, integration: integration}
    end

    test "reactivates an :error integration, clearing failure state", %{
      user: user,
      integration: integration
    } do
      {:ok, errored} =
        Integrations.record_integration_poll_failure(integration, %{last_error: "boom"},
          authorize?: false
        )

      {:ok, errored} = Integrations.mark_integration_errored(errored, authorize?: false)
      assert errored.status == :error
      assert errored.consecutive_failures > 0

      assert {:ok, reactivated} = Integrations.reactivate_if_errored(errored, actor: user)

      assert reactivated.status == :active
      assert reactivated.consecutive_failures == 0
      assert reactivated.last_error == nil
      assert reactivated.error_message == nil
    end

    test "leaves a :pending integration untouched", %{user: user, integration: integration} do
      assert integration.status == :pending

      assert {:ok, unchanged} =
               Integrations.reactivate_if_errored(integration, actor: user)

      assert unchanged.status == :pending
      assert unchanged == integration
    end

    test "leaves an :active integration untouched", %{user: user, integration: integration} do
      {:ok, active} = Integrations.activate_user_integration(integration, actor: user)

      assert {:ok, unchanged} = Integrations.reactivate_if_errored(active, actor: user)

      assert unchanged.status == :active
      assert unchanged == active
    end

    test "does NOT reactivate a user-disabled integration", %{
      user: user,
      integration: integration
    } do
      {:ok, disabled} = Integrations.deactivate_user_integration(integration, actor: user)
      assert disabled.status == :disabled

      assert {:ok, unchanged} = Integrations.reactivate_if_errored(disabled, actor: user)

      assert unchanged.status == :disabled
    end
  end

  describe "audit_log" do
    test "can record audit entry" do
      user = generate(user())

      {:ok, audit} =
        Integrations.record_audit(
          %{
            user_id: user.id,
            provider_key: :test,
            operation: "webhook",
            status: :success,
            ip_address: "192.168.1.1",
            metadata: %{some: "data"}
          },
          authorize?: false
        )

      assert audit.user_id == user.id
      assert audit.provider_key == :test
      assert audit.status == :success
    end
  end
end
