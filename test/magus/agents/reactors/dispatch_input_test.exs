defmodule Magus.Agents.Reactors.DispatchInputTest do
  @moduledoc """
  Tests that DispatchInput arms the stuck-message sweep by transitioning the
  InputMessage to :processing at the start of its run, then :processed once the
  message has been routed.

  The reactor does NOT block for the agent's LLM turn (Chat.send_user_message's
  SignalAgent change dispatches asynchronously), so it completes in seconds and
  the InputMessage never sits in :processing long enough for the 15-minute
  sweep to fail it on the happy path.
  """
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Reactors.DispatchInput
  alias Magus.Integrations

  defp create_integration(user) do
    {:ok, agent} = Magus.Agents.create_custom_agent(%{name: "Dispatch Agent"}, actor: user)

    {:ok, integration} =
      Integrations.create_user_integration(
        :simple_webhook,
        %{
          user_id: user.id,
          custom_agent_id: agent.id,
          config: %{}
        },
        authorize?: false
      )

    {:ok, integration} = Integrations.activate_user_integration(integration, authorize?: false)
    integration
  end

  defp create_input_message(user, integration) do
    # dispatched: true so the create action's SignalInputAgent change does not
    # itself spawn an async DispatchInput run — this test drives the reactor
    # directly and asserts on the resulting status.
    {:ok, message} =
      Integrations.create_input_message(
        %{
          provider_key: :simple_webhook,
          message_type: :text,
          payload: %{"text" => "hello", "sender_id" => "sender-1"},
          user_id: user.id,
          user_integration_id: integration.id,
          dispatched: true
        },
        authorize?: false
      )

    message
  end

  test "marks the input :processing then :processed over a successful run" do
    user = generate(user())
    integration = create_integration(user)
    message = create_input_message(user, integration)

    assert message.status == :pending

    {:ok, _result} =
      Reactor.run(
        DispatchInput,
        %{input_message_id: message.id, user_id: user.id},
        async?: false
      )

    {:ok, reloaded} = Integrations.get_input_message(message.id, authorize?: false)

    # The run completed: the message advanced past :processing to :processed
    # (mark_processing at the start, mark_processed at the end).
    assert reloaded.status == :processed
    refute reloaded.status == :pending
  end
end
