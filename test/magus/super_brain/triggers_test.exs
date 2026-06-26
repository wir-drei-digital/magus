defmodule Magus.SuperBrain.TriggersTest do
  @moduledoc """
  Verifies that creating or updating the four extraction-target resources
  enqueues the matching Super Brain worker via an Oban job.

  Tests only assert on `args` (the `resource_id` payload) so they remain
  robust if the worker module ever moves; the `unique` constraint on each
  worker (set in `ExtractBase.__using__`) absorbs duplicate enqueues from
  unrelated side effects in the same test.
  """

  use Magus.ResourceCase, async: false

  use Oban.Testing, repo: Magus.Repo

  describe "brain page trigger" do
    test "creating a page enqueues ExtractBrainPage" do
      user = generate(user())
      brain = generate(brain(user_id: user.id))
      page = brain_page(brain_id: brain.id, user_id: user.id, content: "hello")

      assert_enqueued(args: %{"resource_id" => page.id})
    end
  end

  describe "memory trigger" do
    test "creating a :user memory enqueues ExtractMemory" do
      user = generate(user())
      memory = memory(user_id: user.id, scope: :user)

      assert_enqueued(args: %{"resource_id" => memory.id})
    end

    test "creating a :local memory does NOT enqueue ExtractMemory" do
      user = generate(user())
      conversation = generate(conversation(actor: user))
      memory = memory(user_id: user.id, scope: :local, conversation_id: conversation.id)

      refute_enqueued(args: %{"resource_id" => memory.id})
    end
  end

  describe "file chunk trigger" do
    test "creating a chunk enqueues ExtractFileChunk" do
      user = generate(user())
      file = generate(file(user_id: user.id, type: :text))
      chunk = generate(chunk(file_id: file.id, content: "hi"))

      assert_enqueued(args: %{"resource_id" => chunk.id})
    end
  end

  describe "draft trigger" do
    test "creating a draft enqueues ExtractDraft" do
      user = generate(user())
      draft = draft(user_id: user.id, content: "hello")

      assert_enqueued(args: %{"resource_id" => draft.id})
    end
  end
end
