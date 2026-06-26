defmodule Magus.Memory.MemorySourceTest do
  @moduledoc """
  Tests for the MemorySource resource.

  Tests cover:
  - Creating sources with valid attributes
  - source_type validation (only valid atoms accepted)
  - Requires memory_id
  - Relationship loading
  """
  use Magus.ResourceCase, async: true
  use Oban.Testing, repo: Magus.Repo

  alias Magus.Memory

  describe "MemorySource.create" do
    test "creates a source with valid attributes" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, mem} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Source Test",
          %{content: %{"key" => "val"}},
          actor: user
        )

      {:ok, source} =
        Memory.create_memory_source(
          mem.id,
          %{source_type: :conversation, source_uri: "conv:#{conversation.id}", title: "Chat"},
          authorize?: false
        )

      assert source.source_type == :conversation
      assert source.source_uri == "conv:#{conversation.id}"
      assert source.title == "Chat"
      assert source.memory_id == mem.id
    end

    test "creates sources of each valid type" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, mem} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Multi Source",
          %{},
          actor: user
        )

      for source_type <- [:conversation, :file, :url, :manual] do
        {:ok, source} =
          Memory.create_memory_source(
            mem.id,
            %{source_type: source_type},
            authorize?: false
          )

        assert source.source_type == source_type
      end
    end

    test "rejects invalid source_type" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, mem} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Bad Source",
          %{},
          actor: user
        )

      {:error, _error} =
        Memory.create_memory_source(
          mem.id,
          %{source_type: :invalid_type},
          authorize?: false
        )
    end

    test "requires memory_id" do
      {:error, _error} =
        Memory.create_memory_source(
          nil,
          %{source_type: :manual},
          authorize?: false
        )
    end

    test "memory relationship loads via sources" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, mem} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Rel Test",
          %{},
          actor: user
        )

      {:ok, _source} =
        Memory.create_memory_source(
          mem.id,
          %{source_type: :url, source_uri: "https://example.com", title: "Example"},
          authorize?: false
        )

      {:ok, loaded} = Memory.get_memory(mem.id, actor: user, load: [:sources])
      assert length(loaded.sources) == 1
      assert hd(loaded.sources).source_type == :url
      assert hd(loaded.sources).title == "Example"
    end

    test "stores optional context_snippet" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, mem} =
        Memory.create_memory(
          conversation.id,
          user.id,
          "Snippet Test",
          %{},
          actor: user
        )

      {:ok, source} =
        Memory.create_memory_source(
          mem.id,
          %{source_type: :manual, context_snippet: "Extracted from paragraph 3"},
          authorize?: false
        )

      assert source.context_snippet == "Extracted from paragraph 3"
    end
  end
end
