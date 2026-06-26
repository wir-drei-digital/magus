defmodule Magus.Chat.SignalAgentQueuedTest do
  use ExUnit.Case, async: true

  alias Magus.Chat.Message.Changes.SignalAgent

  test "queued messages are not dispatched" do
    # A queued message reaching the after_transaction branch must short-circuit
    # before Dispatcher is called. We assert the guard directly.
    assert SignalAgent.dispatchable?(%{role: :user, status: :complete}) == true
    assert SignalAgent.dispatchable?(%{role: :user, status: :queued}) == false
    assert SignalAgent.dispatchable?(%{role: :agent, status: :complete}) == false
  end
end
