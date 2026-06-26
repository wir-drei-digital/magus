defmodule Magus.Agents.Workers.ResumeGenerationWorkerTest do
  use Magus.DataCase, async: false
  use Oban.Testing, repo: Magus.Repo

  import Magus.Generators

  alias Magus.Agents.Workers.ResumeGenerationWorker

  describe "perform/1" do
    test "returns cancel when conversation does not exist" do
      fake_id = Ash.UUID.generate()

      assert {:cancel, :conversation_not_found} =
               perform_job(ResumeGenerationWorker, %{"conversation_id" => fake_id})
    end

    test "returns cancel when conversation has no user messages" do
      user = generate(user())
      conversation = generate(conversation(actor: user))

      assert {:cancel, :no_user_messages} =
               perform_job(ResumeGenerationWorker, %{
                 "conversation_id" => to_string(conversation.id)
               })
    end

    test "returns cancel when generation already completed" do
      user = generate(user())
      conversation = generate(conversation(actor: user))
      _user_msg = generate(message(actor: user, conversation_id: conversation.id, text: "Hello"))

      # Create a complete agent response after the user message
      Magus.Chat.Message
      |> Ash.Changeset.for_create(
        :upsert_response,
        %{
          id: Ash.UUID.generate(),
          conversation_id: conversation.id,
          text: "Agent response",
          complete: true,
          model_name: "test-model",
          mode: :chat
        },
        actor: %Magus.Agents.Support.AiAgent{}
      )
      |> Ash.create!()

      assert {:cancel, :already_complete} =
               perform_job(ResumeGenerationWorker, %{
                 "conversation_id" => to_string(conversation.id)
               })
    end
  end
end
