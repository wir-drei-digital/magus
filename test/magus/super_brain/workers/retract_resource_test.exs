defmodule Magus.SuperBrain.Workers.RetractResourceTest do
  @moduledoc """
  Tests for `Magus.SuperBrain.Workers.RetractResource`.

  Covers both halves of the worker: the Postgres cleanup (deleting Episode
  rows for a resource, which cascades to Claims via FK) and the enqueue path
  from `Magus.Memory.Memory`'s `:destroy` action. The FalkorDB graph delete
  is exercised via the `graph_name: nil` no-op path only - it does not
  require a live FalkorDB connection.
  """

  use Magus.ResourceCase, async: false
  use Oban.Testing, repo: Magus.Repo

  require Ash.Query

  alias Magus.SuperBrain.Episode
  alias Magus.SuperBrain.Workers.RetractResource

  describe "enqueue on memory destroy" do
    test "destroying a user-scope memory enqueues RetractResource" do
      user = generate(user())

      {:ok, memory} =
        Magus.Memory.create_user_memory(user.id, nil, "fact", %{content: %{}, summary: "s"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      assert :ok = Magus.Memory.destroy_memory(memory, actor: user)

      assert_enqueued(
        worker: RetractResource,
        args: %{
          "resource_type" => "memory",
          "resource_id" => memory.id,
          "graph_name" => "memories:user:#{user.id}"
        }
      )
    end

    test "destroying an agent-scope memory enqueues RetractResource routed to the owner's graph" do
      user = generate(user())
      agent = custom_agent(user)

      {:ok, memory} =
        Magus.Memory.create_agent_memory(
          user.id,
          agent.id,
          %{name: "fact", content: %{}, summary: "s"},
          actor: %Magus.Agents.Support.AiAgent{}
        )

      assert :ok = Magus.Memory.destroy_memory(memory, actor: user)

      assert_enqueued(
        worker: RetractResource,
        args: %{
          "resource_type" => "memory",
          "resource_id" => memory.id,
          "graph_name" => "memories:user:#{user.id}"
        }
      )
    end

    test "destroying a local-scope memory does not enqueue RetractResource" do
      user = generate(user())
      {:ok, conversation} = Magus.Chat.create_conversation(%{}, actor: user)

      memory = memory(conversation_id: conversation.id, user_id: user.id)

      assert :ok = Magus.Memory.destroy_memory(memory, actor: user)

      refute_enqueued(worker: RetractResource, args: %{"resource_id" => memory.id})
    end
  end

  describe "perform/1" do
    test "deletes the matching Episode rows and cascades to Claims" do
      user = generate(user())
      resource_id = Ash.UUID.generate()

      {:ok, episode} =
        Ash.create(
          Episode,
          %{
            resource_type: :memory,
            resource_id: resource_id,
            graph_name: "memories:user:#{user.id}",
            raw_text: "some memory content",
            source_user_id: user.id
          },
          actor: user
        )

      {:ok, claim} =
        Ash.create(
          Magus.SuperBrain.Claim,
          %{
            graph_name: "memories:user:#{user.id}",
            episode_id: episode.id,
            source_user_id: user.id,
            subject_name: "Berlin",
            subject_key: "location:berlin",
            object_name: "Germany",
            object_key: "location:germany",
            predicate: "located_in",
            claim_text: "Berlin is located in Germany"
          },
          action: :bulk_create,
          authorize?: false
        )

      # A different resource_id's Episode must survive the retraction.
      {:ok, other_episode} =
        Ash.create(
          Episode,
          %{
            resource_type: :memory,
            resource_id: Ash.UUID.generate(),
            graph_name: "memories:user:#{user.id}",
            raw_text: "unrelated memory",
            source_user_id: user.id
          },
          actor: user
        )

      assert :ok =
               perform_job(RetractResource, %{
                 "resource_type" => "memory",
                 "resource_id" => resource_id,
                 "graph_name" => nil
               })

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(Episode, episode.id, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(Magus.SuperBrain.Claim, claim.id, authorize?: false)

      assert {:ok, _} = Ash.get(Episode, other_episode.id, authorize?: false)
    end

    test "graph_name nil skips the graph delete without error" do
      resource_id = Ash.UUID.generate()

      assert :ok =
               perform_job(RetractResource, %{
                 "resource_type" => "memory",
                 "resource_id" => resource_id,
                 "graph_name" => nil
               })
    end

    test "defaults resource_type to memory when not provided" do
      user = generate(user())
      resource_id = Ash.UUID.generate()

      {:ok, episode} =
        Ash.create(
          Episode,
          %{
            resource_type: :memory,
            resource_id: resource_id,
            graph_name: "memories:user:#{user.id}",
            raw_text: "some memory content",
            source_user_id: user.id
          },
          actor: user
        )

      assert :ok =
               perform_job(RetractResource, %{
                 "resource_id" => resource_id,
                 "graph_name" => nil
               })

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.get(Episode, episode.id, authorize?: false)
    end
  end
end
