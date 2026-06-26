defmodule Magus.SuperBrain.EpisodeTest do
  use Magus.ResourceCase, async: true

  alias Magus.SuperBrain.Episode

  describe "create" do
    test "creates an episode with fingerprint" do
      user = generate(user())

      attrs = %{
        resource_type: :brain_page,
        resource_id: Ash.UUID.generate(),
        graph_name: "brain:abc",
        raw_text: "Some content",
        source_user_id: user.id
      }

      assert {:ok, episode} = Ash.create(Episode, attrs, actor: user)
      assert episode.status == :pending
      assert episode.attempt_count == 0
      assert is_binary(episode.content_fingerprint)
      assert episode.source_weight == 1.0
    end

    test "computes the same fingerprint for identical raw_text" do
      user = generate(user())

      attrs = fn ->
        %{
          resource_type: :brain_page,
          resource_id: Ash.UUID.generate(),
          graph_name: "brain:abc",
          raw_text: "same text",
          source_user_id: user.id
        }
      end

      {:ok, e1} = Ash.create(Episode, attrs.(), actor: user)
      {:ok, e2} = Ash.create(Episode, attrs.(), actor: user)

      assert e1.content_fingerprint == e2.content_fingerprint
    end

    test "accepts :file_chunk as a resource_type" do
      user = generate(user())

      attrs = %{
        resource_type: :file_chunk,
        resource_id: Ash.UUID.generate(),
        graph_name: "files:user:#{user.id}",
        raw_text: "chunk content",
        source_user_id: user.id
      }

      assert {:ok, episode} = Ash.create(Episode, attrs, actor: user)
      assert episode.resource_type == :file_chunk
    end
  end

  describe "mark_processing/mark_extracted/mark_failed" do
    test "transitions through lifecycle" do
      user = generate(user())

      {:ok, episode} =
        Ash.create(
          Episode,
          %{
            resource_type: :brain_page,
            resource_id: Ash.UUID.generate(),
            graph_name: "brain:abc",
            raw_text: "text",
            source_user_id: user.id
          },
          actor: user
        )

      {:ok, episode} = Ash.update(episode, %{}, action: :mark_processing, actor: user)
      assert episode.status == :processing

      {:ok, episode} = Ash.update(episode, %{}, action: :mark_extracted, actor: user)
      assert episode.status == :extracted
      assert not is_nil(episode.extracted_at)
    end
  end

  describe "list_pending" do
    test "returns only pending episodes" do
      user = generate(user())

      make_episode = fn ->
        {:ok, e} =
          Ash.create(
            Episode,
            %{
              resource_type: :brain_page,
              resource_id: Ash.UUID.generate(),
              graph_name: "brain:abc",
              raw_text: "text-#{System.unique_integer()}",
              source_user_id: user.id
            },
            actor: user
          )

        e
      end

      pending = make_episode.()
      extracted = make_episode.()
      {:ok, _} = Ash.update(extracted, %{}, action: :mark_processing, actor: user)
      {:ok, _} = Ash.update(extracted, %{}, action: :mark_extracted, actor: user)

      {:ok, results} = Ash.read(Episode, action: :list_pending, actor: user)
      ids = Enum.map(results, & &1.id)

      assert pending.id in ids
      assert extracted.id not in ids
    end
  end
end
