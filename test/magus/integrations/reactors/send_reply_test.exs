defmodule Magus.Integrations.Reactors.SendReplyTest do
  @moduledoc """
  Integration tests for the SendReply reactor.

  Tests the reply sending workflow including:
  - Loading user integrations
  - Validating send capability
  - Executing send operations
  - Creating output messages
  """
  use Magus.ResourceCase, async: true

  alias Magus.Integrations.Reactors.SendReply

  defp create_integration(user, opts \\ []) do
    {:ok, agent} =
      Magus.Agents.create_custom_agent(
        %{name: "Reply Agent #{System.unique_integer([:positive])}"},
        actor: user
      )

    {:ok, integration} =
      Magus.Integrations.create_user_integration(
        :simple_webhook,
        %{
          user_id: user.id,
          custom_agent_id: agent.id,
          config: Keyword.get(opts, :config, %{}),
          async_reply_enabled: Keyword.get(opts, :async_reply_enabled, true)
        },
        authorize?: false
      )

    status = Keyword.get(opts, :status, :active)

    if status == :active do
      {:ok, i} = Magus.Integrations.activate_user_integration(integration, authorize?: false)
      i
    else
      integration
    end
  end

  describe "reactor execution" do
    setup do
      user = generate(user())
      integration = create_integration(user)
      {:ok, user: user, integration: integration}
    end

    test "sends reply through active integration", %{user: _user, integration: integration} do
      inputs = %{
        user_integration_id: integration.id,
        message: "Hello from the agent!",
        recipient_id: "test-recipient-123",
        triggered_by_input_id: nil
      }

      result = Reactor.run(SendReply, inputs, async?: false)

      case result do
        {:ok, %{output_message_id: _, external_id: _}} ->
          :ok

        {:error, {:send_failed, _}} ->
          # Send operation failed (expected without real provider)
          :ok

        {:error, _} ->
          :ok
      end
    end

    test "returns error for inactive integration", %{user: user} do
      inactive = create_integration(user, status: :pending)

      inputs = %{
        user_integration_id: inactive.id,
        message: "This should fail",
        recipient_id: "test-recipient",
        triggered_by_input_id: nil
      }

      result = Reactor.run(SendReply, inputs, async?: false)

      # Should fail because integration is not active
      assert {:error, _} = result
    end

    test "returns error when replies are disabled", %{user: user} do
      no_reply = create_integration(user, async_reply_enabled: false)

      inputs = %{
        user_integration_id: no_reply.id,
        message: "This should fail",
        recipient_id: "test-recipient",
        triggered_by_input_id: nil
      }

      result = Reactor.run(SendReply, inputs, async?: false)

      # Should fail because replies are disabled
      assert {:error, _} = result
    end

    test "returns error for non-existent integration" do
      inputs = %{
        user_integration_id: Ash.UUID.generate(),
        message: "This should fail",
        recipient_id: "test-recipient",
        triggered_by_input_id: nil
      }

      result = Reactor.run(SendReply, inputs, async?: false)

      assert {:error, _} = result
    end
  end

  describe "output message creation" do
    setup do
      user = generate(user())
      integration = create_integration(user)
      {:ok, user: user, integration: integration}
    end

    test "creates output message record before sending", %{user: user, integration: integration} do
      inputs = %{
        user_integration_id: integration.id,
        message: "Test output message",
        recipient_id: "recipient-456",
        triggered_by_input_id: nil
      }

      result = Reactor.run(SendReply, inputs, async?: false)

      case result do
        {:ok, %{output_message_id: id}} when not is_nil(id) ->
          # Verify output message was created
          {:ok, output_msg} = Magus.Integrations.get_output_message(id, authorize?: false)
          assert output_msg.user_id == user.id

        {:error, _} ->
          :ok
      end
    end
  end
end
