defmodule Magus.Agents.Tools.Files.SearchAttachedDocsTest do
  use Magus.DataCase, async: false

  import Magus.Generators

  alias Magus.Agents.Tools.Files.SearchAttachedDocs

  setup do
    user = generate(user())
    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    agent = custom_agent(user)

    {:ok, search_file} =
      Magus.Files.create_file(
        %{
          name: "Manual.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "tmp/m.pdf"
        },
        actor: user
      )

    {:ok, other_file} =
      Magus.Files.create_file(
        %{
          name: "Other.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1,
          file_path: "tmp/o.pdf"
        },
        actor: user
      )

    seed_chunk!(search_file, "How to file an expense report.", 0, fixed_embedding(1.0))
    seed_chunk!(other_file, "Unrelated content not attached.", 0, fixed_embedding(0.0))

    {:ok, _} =
      Magus.Agents.create_attachment(
        %{custom_agent_id: agent.id, file_id: search_file.id, mode: :search},
        actor: user
      )

    %{user: user, agent: agent, search_file: search_file, other_file: other_file}
  end

  test "search_mode_file_ids returns only the search-mode attached files", %{
    agent: agent,
    search_file: search_file
  } do
    file_ids = SearchAttachedDocs.search_mode_file_ids(agent.id)
    assert file_ids == [search_file.id]
  end

  test "returns empty results when no :search-mode attachments exist for the agent", %{
    user: user
  } do
    other_agent = custom_agent(user)

    {:ok, %{results: results}} =
      SearchAttachedDocs.run(
        %{"query" => "anything", "limit" => 5},
        %{
          user_id: user.id,
          conversation_id: Ecto.UUID.generate(),
          custom_agent_id: other_agent.id
        }
      )

    assert results == []
  end

  test "returns empty results when query is blank", %{user: user, agent: agent} do
    {:ok, %{results: results}} =
      SearchAttachedDocs.run(
        %{"query" => "", "limit" => 5},
        %{user_id: user.id, conversation_id: Ecto.UUID.generate(), custom_agent_id: agent.id}
      )

    assert results == []
  end

  test "do_search restricts to provided file_ids", %{
    user: user,
    agent: agent,
    search_file: search_file
  } do
    # Direct test of search using a fixed embedding (bypasses external API).
    file_ids = SearchAttachedDocs.search_mode_file_ids(agent.id)
    assert file_ids == [search_file.id]

    {:ok, %{results: results}} =
      SearchAttachedDocs.do_search(fixed_embedding(1.0), file_ids, 5, %{user: user})

    assert Enum.all?(results, fn r -> r.file_id == search_file.id end)
  end

  test "returns error for missing custom_agent_id in context", %{user: user} do
    {:ok, %{error: msg}} =
      SearchAttachedDocs.run(
        %{"query" => "anything"},
        %{user_id: user.id}
      )

    assert msg =~ "custom_agent_id"
  end

  defp fixed_embedding(v) do
    # text-embedding-3-small produces 1536-dim vectors.
    List.duplicate(v, 1536)
  end

  defp seed_chunk!(file, content, position, embedding) do
    {:ok, _} =
      Magus.Files.Chunk
      |> Ash.Changeset.for_create(:create, %{
        file_id: file.id,
        content: content,
        position: position,
        token_count: max(div(byte_size(content), 4), 1),
        embedding: embedding
      })
      |> Ash.create(authorize?: false)
  end
end
