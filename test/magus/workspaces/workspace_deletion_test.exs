defmodule Magus.Workspaces.WorkspaceDeletionTest do
  use Magus.DataCase, async: false

  import Magus.Generators
  require Ash.Query

  alias Magus.Workspaces.WorkspaceDeletion

  setup do
    user = generate(user())
    ensure_workspace_plan(user)
    ws = generate(workspace(actor: user))
    %{user: user, workspace: ws}
  end

  describe "preflight/1" do
    test "returns zero counts for an empty workspace", %{workspace: ws} do
      assert {:ok, summary} = WorkspaceDeletion.preflight(ws)

      assert summary.conversation_count == 0
      assert summary.file_count == 0
      assert summary.prompt_count == 0
      # a default custom agent is auto-created with every workspace
      assert summary.custom_agent_count == 1
      assert summary.knowledge_source_count == 0
      # the creator is an active member
      assert summary.member_count == 1
    end

    test "counts workspace-scoped resources", %{user: user, workspace: ws} do
      generate(conversation(actor: user, workspace_id: ws.id))
      generate(conversation(actor: user, workspace_id: ws.id))
      generate(file(actor: user, workspace_id: ws.id))
      generate(prompt(actor: user, workspace_id: ws.id))

      {:ok, summary} = WorkspaceDeletion.preflight(ws)

      assert summary.conversation_count == 2
      assert summary.file_count == 1
      assert summary.prompt_count == 1
    end
  end

  describe "execute/2" do
    test "refuses without an actor", %{workspace: ws} do
      assert {:error, :not_authorized} = WorkspaceDeletion.execute(ws)
    end

    test "refuses a non-admin actor", %{workspace: ws} do
      stranger = generate(user())
      assert {:error, :not_authorized} = WorkspaceDeletion.execute(ws, actor: stranger)
    end

    test "deletes the workspace row", %{user: user, workspace: ws} do
      assert :ok = WorkspaceDeletion.execute(ws, actor: user)
      assert {:error, _} = Ash.get(Magus.Workspaces.Workspace, ws.id, authorize?: false)
    end

    test "hard-deletes workspace conversations and their messages",
         %{user: user, workspace: ws} do
      conv = generate(conversation(actor: user, workspace_id: ws.id))
      _msg = generate(message(actor: user, conversation_id: conv.id))

      assert :ok = WorkspaceDeletion.execute(ws, actor: user)

      assert Magus.Chat.Conversation
             |> Ash.Query.filter(id == ^conv.id)
             |> Ash.count!(authorize?: false) == 0

      assert Magus.Chat.Message
             |> Ash.Query.filter(conversation_id == ^conv.id)
             |> Ash.count!(authorize?: false) == 0
    end

    test "preserves message_usage rows with message_id NULLed",
         %{user: user, workspace: ws} do
      conv = generate(conversation(actor: user, workspace_id: ws.id))
      msg = generate(message(actor: user, conversation_id: conv.id))

      Magus.Repo.query!(
        """
        INSERT INTO message_usages
          (id, message_id, user_id, model, usage_type, prompt_tokens, completion_tokens, total_tokens, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW(), NOW())
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          Ecto.UUID.dump!(msg.id),
          Ecto.UUID.dump!(user.id),
          "openrouter:test-model",
          "completion",
          10,
          5,
          15
        ]
      )

      :ok = WorkspaceDeletion.execute(ws, actor: user)

      # Usage row survives, message_id was nullified by FK cascade
      {:ok, %{rows: rows}} =
        Magus.Repo.query(
          "SELECT message_id FROM message_usages WHERE user_id = $1",
          [Ecto.UUID.dump!(user.id)]
        )

      assert length(rows) == 1
      assert [[nil]] = rows
    end

    test "hard-deletes workspace files", %{user: user, workspace: ws} do
      _file = generate(file(actor: user, workspace_id: ws.id))

      :ok = WorkspaceDeletion.execute(ws, actor: user)

      assert Magus.Files.File
             |> Ash.Query.filter(workspace_id == ^ws.id)
             |> Ash.count!(authorize?: false) == 0
    end

    test "hard-deletes workspace prompts", %{user: user, workspace: ws} do
      _prompt = generate(prompt(actor: user, workspace_id: ws.id))

      :ok = WorkspaceDeletion.execute(ws, actor: user)

      assert Magus.Library.Prompt
             |> Ash.Query.filter(workspace_id == ^ws.id)
             |> Ash.count!(authorize?: false) == 0
    end

    test "hard-deletes workspace skills", %{user: user, workspace: ws} do
      {:ok, _skill} =
        Magus.Skills.create_skill(
          %{name: "ws-skill", description: "x", workspace_id: ws.id},
          actor: user
        )

      :ok = WorkspaceDeletion.execute(ws, actor: user)

      assert Magus.Skills.Skill
             |> Ash.Query.filter(workspace_id == ^ws.id)
             |> Ash.count!(authorize?: false) == 0
    end

    test "removes workspace members", %{user: user, workspace: ws} do
      :ok = WorkspaceDeletion.execute(ws, actor: user)

      assert Magus.Workspaces.WorkspaceMember
             |> Ash.Query.filter(workspace_id == ^ws.id)
             |> Ash.count!(authorize?: false) == 0
    end

    test "clears current_workspace_id on users that had it set",
         %{user: user, workspace: ws} do
      {:ok, _} =
        user
        |> Ash.Changeset.for_update(
          :select_workspace,
          %{current_workspace_id: ws.id},
          actor: user
        )
        |> Ash.update()

      :ok = WorkspaceDeletion.execute(ws, actor: user)

      reloaded = Ash.get!(Magus.Accounts.User, user.id, authorize?: false)
      assert reloaded.current_workspace_id == nil
    end

    test "cleans agent_runs referencing workspace conversations",
         %{user: user, workspace: ws} do
      conv = generate(conversation(actor: user, workspace_id: ws.id))

      Magus.Repo.query!(
        """
        INSERT INTO agent_runs
          (id, kind, source, status, source_conversation_id, target_conversation_id,
           request_id, objective, inserted_at, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, NOW(), NOW())
        """,
        [
          Ecto.UUID.dump!(Ecto.UUID.generate()),
          "consult",
          "mention",
          "pending",
          Ecto.UUID.dump!(conv.id),
          Ecto.UUID.dump!(conv.id),
          "req-test-#{System.unique_integer([:positive])}",
          "test objective"
        ]
      )

      assert :ok = WorkspaceDeletion.execute(ws, actor: user)

      {:ok, %{rows: [[count]]}} =
        Magus.Repo.query(
          "SELECT COUNT(*) FROM agent_runs WHERE source_conversation_id = $1",
          [Ecto.UUID.dump!(conv.id)]
        )

      assert count == 0
    end

    test "deletes resource_accesses where workspace is grantee", %{user: user, workspace: ws} do
      # Grant a workspace-scoped role on a conversation in this workspace
      conv = generate(conversation(actor: user, workspace_id: ws.id))

      {:ok, _grant} =
        Magus.Workspaces.grant_access(
          %{
            resource_type: :conversation,
            resource_id: conv.id,
            grantee_type: :workspace,
            grantee_id: ws.id,
            role: :viewer
          },
          actor: user
        )

      :ok = WorkspaceDeletion.execute(ws, actor: user)

      {:ok, %{rows: [[count]]}} =
        Magus.Repo.query(
          "SELECT COUNT(*) FROM resource_accesses WHERE grantee_type = 'workspace' AND grantee_id = $1",
          [Ecto.UUID.dump!(ws.id)]
        )

      assert count == 0
    end

    test "cleans up mcp_server resource_accesses grants", %{user: user, workspace: ws} do
      {:ok, server} =
        Magus.MCP.create_server(
          %{
            name: "Team MCP",
            handle: "teammcp",
            url: "https://93.184.216.34",
            workspace_id: ws.id
          },
          actor: user
        )

      member = generate(user())
      workspace_member(user_id: member.id, workspace_id: ws.id, role: :member)

      {:ok, _grant} =
        Magus.Workspaces.grant_access(
          %{
            resource_type: :mcp_server,
            resource_id: server.id,
            grantee_type: :user,
            grantee_id: member.id,
            role: :viewer
          },
          actor: user
        )

      :ok = WorkspaceDeletion.execute(ws, actor: user)

      {:ok, %{rows: [[count]]}} =
        Magus.Repo.query(
          "SELECT COUNT(*) FROM resource_accesses WHERE resource_type = 'mcp_server' AND resource_id = $1",
          [Ecto.UUID.dump!(server.id)]
        )

      assert count == 0
    end

    test "leaves personal-scope content of other users untouched", %{user: user} do
      other_user = generate(user())
      ensure_workspace_plan(other_user)
      personal_conv = generate(conversation(actor: other_user))

      ws = generate(workspace(actor: user))
      generate(conversation(actor: user, workspace_id: ws.id))

      :ok = WorkspaceDeletion.execute(ws, actor: user)

      reloaded =
        Magus.Chat.Conversation
        |> Ash.Query.filter(id == ^personal_conv.id)
        |> Ash.read_one!(authorize?: false)

      assert reloaded.id == personal_conv.id
    end
  end
end
