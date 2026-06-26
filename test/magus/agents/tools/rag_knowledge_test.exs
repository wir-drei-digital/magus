defmodule Magus.Agents.Tools.RagKnowledgeTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Rag
  alias Magus.Knowledge

  defp create_knowledge_file(user, collection) do
    {:ok, file} =
      Magus.Files.create_file_from_connector(
        %{
          name: "test-file-#{System.unique_integer([:positive])}.txt",
          type: :document,
          mime_type: "text/plain",
          file_size: 1024,
          file_path: "/tmp/test-file-#{System.unique_integer([:positive])}.txt",
          knowledge_collection_id: collection.id,
          external_id: "ext_file_#{System.unique_integer([:positive])}"
        },
        actor: user
      )

    # Mark file as ready so it's found by knowledge resolution
    file
    |> Ash.Changeset.for_update(:update_status, %{status: :ready})
    |> Ash.update!(authorize?: false)
  end

  defp create_source(user) do
    {:ok, source} =
      Knowledge.create_source(
        %{name: "Test Source", provider: :notion, auth_config: %{"key" => "test"}},
        actor: user
      )

    source
  end

  defp create_collection(user, source) do
    {:ok, collection} =
      Knowledge.create_collection(
        source.id,
        %{
          name: "Test Collection",
          external_id: "ext_coll_#{System.unique_integer([:positive])}",
          external_path: "/test"
        },
        actor: user
      )

    collection
  end

  describe "run/2 with knowledge context" do
    setup do
      user = generate(user())
      free_plan = ensure_free_plan()

      {:ok, _sub} =
        Magus.Usage.create_user_subscription(
          %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
          authorize?: false
        )

      source = create_source(user)
      collection = create_collection(user, source)

      %{user: user, source: source, collection: collection}
    end

    test "includes knowledge files when resource_ids is empty", %{
      user: user,
      collection: collection
    } do
      # Create a ready file linked to the collection
      file = create_knowledge_file(user, collection)

      # Grant user access to the collection
      {:ok, _access} =
        Magus.Workspaces.grant_access(
          %{
            resource_type: :knowledge_collection,
            resource_id: collection.id,
            grantee_type: :user,
            grantee_id: user.id,
            role: :viewer
          },
          actor: user
        )

      # Verify the knowledge resolution finds the file
      {:ok, file_ids} = Knowledge.get_accessible_file_ids(user_id: user.id)
      assert file.id in file_ids

      context = %{
        user_id: user.id,
        user: user,
        workspace_id: nil,
        custom_agent_id: nil,
        can_access_knowledge: true
      }

      # With knowledge files available, the RAG tool should NOT return "no documents"
      # It will attempt embedding which will fail in test, but it won't short-circuit
      # with the "no documents" message
      result = Rag.run(%{"query" => "test query"}, context)

      case result do
        {:ok, %{message: msg}} ->
          refute msg == "No documents available. The user hasn't uploaded any files."

        {:error, _} ->
          # Embedding generation failure is expected in test env — the important
          # thing is we got past the empty-check
          :ok

        {:ok, %{results: _}} ->
          :ok
      end
    end

    test "returns 'no documents' when no files exist", %{
      user: user
    } do
      context = %{
        user_id: user.id,
        user: user,
        workspace_id: nil,
        custom_agent_id: nil,
        can_access_knowledge: true
      }

      {:ok, result} = Rag.run(%{"query" => "test query"}, context)
      assert result[:message] == "No documents available. The user hasn't uploaded any files."
    end

    test "skips knowledge resolution when can_access_knowledge is false", %{
      user: user,
      collection: collection
    } do
      # Create a ready file in the collection
      _file = create_knowledge_file(user, collection)

      {:ok, _access} =
        Magus.Workspaces.grant_access(
          %{
            resource_type: :knowledge_collection,
            resource_id: collection.id,
            grantee_type: :user,
            grantee_id: user.id,
            role: :viewer
          },
          actor: user
        )

      # With can_access_knowledge false AND can_access_global_files false,
      # the file should not be found through any path
      context = %{
        user_id: user.id,
        user: user,
        workspace_id: nil,
        custom_agent_id: nil,
        can_access_knowledge: false,
        can_access_global_files: false
      }

      {:ok, result} = Rag.run(%{"query" => "test"}, context)
      assert result[:message] == "No documents available. The user hasn't uploaded any files."
    end

    test "does not crash when context is a plain list (legacy format)" do
      # The list-context fallback has no user actor; the tool returns a generic
      # no-documents message rather than searching.
      {:ok, result} = Rag.run(%{"query" => "test"}, [])
      assert result[:message] =~ "No documents available"
    end
  end
end
