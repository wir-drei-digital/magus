defmodule Magus.Agents.DispatcherActingUserTest do
  @moduledoc """
  Unit test for `acting_user_id` threading from the dispatcher signal.

  `build_signal_data/3` reads only plain map attributes (no DB access), so this
  test uses bare maps and runs async.
  """

  use ExUnit.Case, async: true

  alias Magus.Agents.Dispatcher

  describe "build_signal_data/3 acting_user_id" do
    test "includes acting_user_id from message.created_by_id (the author)" do
      author_id = Ecto.UUID.generate()
      owner_id = Ecto.UUID.generate()

      message = %{
        id: Ecto.UUID.generate(),
        text: "hi",
        created_by_id: author_id,
        mode: :chat,
        metadata: %{},
        attachments: [],
        selected_model_id: nil
      }

      conversation = %{id: Ecto.UUID.generate(), user_id: owner_id, chat_mode: :chat}
      routed = %{routing_reason: nil, model_keys: %{chat: "x"}}

      data = Dispatcher.build_signal_data(message, conversation, routed)

      assert data.acting_user_id == author_id
      # Additive: existing keys remain unchanged.
      assert data.text == "hi"
      assert data.mode == :chat
    end
  end
end
