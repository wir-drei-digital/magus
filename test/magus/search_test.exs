defmodule Magus.SearchTest do
  use Magus.ResourceCase, async: true

  alias Magus.Search

  describe "search/2" do
    test "returns empty results for short queries" do
      assert {:ok, []} = Search.search("a")
      assert {:ok, []} = Search.search("")
    end

    test "searches messages" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      {:ok, _message} =
        Chat.create_message(
          %{
            text: "This is a searchable message about elephants",
            conversation_id: conversation.id
          },
          actor: user
        )

      {:ok, results} = Search.search("elephants", actor: user, types: [:message])

      assert length(results) >= 1
      assert Enum.any?(results, &(&1.type == :message))
    end

    test "searches conversations by title" do
      user = generate(user())

      {:ok, conversation} =
        Chat.create_conversation(%{title: "Unique Zebra Discussion"}, actor: user)

      {:ok, results} = Search.search("zebra", actor: user, types: [:conversation])

      assert length(results) >= 1
      assert Enum.any?(results, fn r -> r.id == conversation.id end)
    end

    test "searches prompts by name and content" do
      user = generate(user())

      {:ok, prompt} =
        Library.create_prompt(
          %{
            name: "Giraffe Helper",
            content: "You are a helpful giraffe expert.",
            type: :system
          },
          actor: user
        )

      {:ok, results} = Search.search("giraffe", actor: user, types: [:prompt])

      assert length(results) >= 1
      assert Enum.any?(results, fn r -> r.id == prompt.id end)
    end

    test "searches across multiple types in parallel" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Penguin Chat"}, actor: user)

      {:ok, _message} =
        Chat.create_message(
          %{
            text: "Let's discuss penguins",
            conversation_id: conversation.id
          },
          actor: user
        )

      {:ok, _prompt} =
        Library.create_prompt(
          %{
            name: "Penguin Expert",
            content: "You know everything about penguins.",
            type: :system
          },
          actor: user
        )

      {:ok, results} =
        Search.search("penguin",
          actor: user,
          types: [:message, :conversation, :prompt]
        )

      types_found = results |> Enum.map(& &1.type) |> Enum.uniq()

      # Should find results from multiple types
      assert length(types_found) >= 2
    end

    test "respects limit option" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{}, actor: user)

      # Create multiple messages
      for i <- 1..10 do
        Chat.create_message(
          %{
            text: "Testing limit message number #{i}",
            conversation_id: conversation.id
          },
          actor: user
        )
      end

      {:ok, results} = Search.search("testing limit", actor: user, limit: 3)

      assert length(results) <= 3
    end

    test "filters by selected types" do
      user = generate(user())
      {:ok, conversation} = Chat.create_conversation(%{title: "Llama Talk"}, actor: user)

      {:ok, _message} =
        Chat.create_message(
          %{
            text: "Llama discussions here",
            conversation_id: conversation.id
          },
          actor: user
        )

      # Only search messages
      {:ok, results} = Search.search("llama", actor: user, types: [:message])

      # All results should be messages
      assert Enum.all?(results, &(&1.type == :message))
    end
  end

  describe "skill search" do
    test "finds an accessible skill by name and description" do
      owner = generate(user())

      {:ok, _} =
        Magus.Skills.create_skill(
          %{name: "pdf-form-filler", description: "Fill PDF forms automatically"},
          actor: owner
        )

      {:ok, results} = Magus.Search.search("pdf-form-filler", actor: owner, types: [:skill])

      assert [%{type: :skill, title: "pdf-form-filler"} | _] = results
    end

    test "does not surface another user's personal skill" do
      owner = generate(user())
      stranger = generate(user())

      {:ok, _} =
        Magus.Skills.create_skill(
          %{name: "secret-pdf-tool", description: "hidden"},
          actor: owner
        )

      {:ok, results} = Magus.Search.search("secret-pdf-tool", actor: stranger, types: [:skill])

      assert results == []
    end
  end

  describe "calculate_score/2" do
    test "returns higher score for exact matches" do
      exact_score = Search.calculate_score("hello world", "hello")
      no_match_score = Search.calculate_score("goodbye planet", "hello")

      assert exact_score > no_match_score
    end

    test "returns 0.0 for nil text" do
      assert Search.calculate_score(nil, "test") == 0.0
    end
  end
end
