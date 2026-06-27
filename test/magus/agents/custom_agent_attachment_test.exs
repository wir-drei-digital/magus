defmodule Magus.Agents.CustomAgentAttachmentTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  setup do
    user = generate(user())
    free_plan = ensure_free_plan()

    {:ok, _subscription} =
      Magus.Usage.create_user_subscription(
        %{user_id: user.id, usage_plan_id: free_plan.id, status: :active},
        authorize?: false
      )

    agent = custom_agent(user)

    {:ok, file} =
      Magus.Files.create_file(
        %{
          name: "guidelines.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 1024,
          file_path: "tmp/guidelines.pdf"
        },
        actor: user
      )

    %{user: user, agent: agent, doc_file: file}
  end

  describe "create" do
    test "creates with mode=:search and default position 0", %{
      user: user,
      agent: agent,
      doc_file: file
    } do
      {:ok, att} =
        Magus.Agents.create_attachment(
          %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
          actor: user
        )

      assert att.mode == :search
      assert att.position == 0
      assert att.custom_agent_id == agent.id
      assert att.file_id == file.id
    end

    test "rejects duplicate (custom_agent_id, file_id)", %{
      user: user,
      agent: agent,
      doc_file: file
    } do
      {:ok, _} =
        Magus.Agents.create_attachment(
          %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
          actor: user
        )

      assert {:error, %Ash.Error.Invalid{}} =
               Magus.Agents.create_attachment(
                 %{custom_agent_id: agent.id, file_id: file.id, mode: :always},
                 actor: user
               )
    end

    test "rejects unknown mode", %{user: user, agent: agent, doc_file: file} do
      assert {:error, %Ash.Error.Invalid{}} =
               Magus.Agents.create_attachment(
                 %{custom_agent_id: agent.id, file_id: file.id, mode: :bogus},
                 actor: user
               )
    end
  end

  describe "agent.attachments" do
    test "loads attachments via the relationship", %{user: user, agent: agent, doc_file: file} do
      {:ok, _att} =
        Magus.Agents.create_attachment(
          %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
          actor: user
        )

      agent = Ash.load!(agent, :attachments, actor: user)
      assert length(agent.attachments) == 1
    end
  end

  describe "permission grants" do
    test "creating an attachment grants the agent :viewer on the file", %{
      user: user,
      agent: agent,
      doc_file: file
    } do
      {:ok, _} =
        Magus.Agents.create_attachment(
          %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
          actor: user
        )

      {:ok, grants} =
        Magus.Workspaces.list_access_for_resource(:file, file.id, actor: user)

      assert Enum.any?(grants, fn g ->
               g.grantee_type == :custom_agent and
                 g.grantee_id == agent.id and
                 g.role == :viewer
             end)
    end

    test "destroying an attachment revokes the agent's grant", %{
      user: user,
      agent: agent,
      doc_file: file
    } do
      {:ok, att} =
        Magus.Agents.create_attachment(
          %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
          actor: user
        )

      :ok = Magus.Agents.destroy_attachment(att, actor: user)

      {:ok, grants} =
        Magus.Workspaces.list_access_for_resource(:file, file.id, actor: user)

      refute Enum.any?(grants, &(&1.grantee_type == :custom_agent and &1.grantee_id == agent.id))
    end
  end

  describe "file destroy cascade" do
    test "destroying the underlying file cascades to attachments", %{
      user: user,
      agent: agent,
      doc_file: file
    } do
      {:ok, _} =
        Magus.Agents.create_attachment(
          %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
          actor: user
        )

      :ok = Magus.Files.delete_file(file, actor: user)

      attachments = Magus.Agents.list_agent_attachments!(agent.id, actor: user)
      assert attachments == []
    end
  end

  describe "limits" do
    setup %{user: user} do
      files =
        for i <- 1..21 do
          {:ok, f} =
            Magus.Files.create_file(
              %{
                name: "f#{i}.pdf",
                type: :document,
                mime_type: "application/pdf",
                file_size: 100,
                file_path: "tmp/f#{i}.pdf"
              },
              actor: user
            )

          f
        end

      %{files: files}
    end

    test "rejects 21st attachment", %{user: user, agent: agent, files: files} do
      for f <- Enum.take(files, 20) do
        {:ok, _} =
          Magus.Agents.create_attachment(
            %{custom_agent_id: agent.id, file_id: f.id, mode: :search},
            actor: user
          )
      end

      twenty_first = Enum.at(files, 20)

      assert {:error, %Ash.Error.Invalid{} = err} =
               Magus.Agents.create_attachment(
                 %{custom_agent_id: agent.id, file_id: twenty_first.id, mode: :search},
                 actor: user
               )

      assert Exception.message(err) =~ "max"
    end
  end

  describe "list_agent_attachments" do
    test "returns attachments ordered by position", %{user: user, agent: agent, doc_file: file} do
      {:ok, file2} =
        Magus.Files.create_file(
          %{
            name: "b.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1,
            file_path: "tmp/b.pdf"
          },
          actor: user
        )

      {:ok, _} =
        Magus.Agents.create_attachment(
          %{custom_agent_id: agent.id, file_id: file.id, mode: :always, position: 1},
          actor: user
        )

      {:ok, _} =
        Magus.Agents.create_attachment(
          %{custom_agent_id: agent.id, file_id: file2.id, mode: :always, position: 0},
          actor: user
        )

      atts = Magus.Agents.list_agent_attachments!(agent.id, actor: user)
      assert Enum.map(atts, & &1.file_id) == [file2.id, file.id]
    end
  end

  describe "agent_attachments action (token budget + status)" do
    test "exposes file_status and token_count summed from the file's chunks", %{
      user: user,
      agent: agent,
      doc_file: file
    } do
      # Chunks are written only by the processing pipeline (the create policy
      # forbids actor writes), so seed them with authorize?: false.
      for {content, tokens, pos} <- [{"alpha", 120, 0}, {"beta", 230, 1}] do
        Ash.create!(
          Magus.Files.Chunk,
          %{file_id: file.id, content: content, position: pos, token_count: tokens},
          action: :create,
          authorize?: false
        )
      end

      {:ok, _att} =
        Magus.Agents.create_attachment(
          %{custom_agent_id: agent.id, file_id: file.id, mode: :always},
          actor: user
        )

      {:ok, [row]} =
        Ash.ActionInput.for_action(
          Magus.Agents.CustomAgent,
          :agent_attachments,
          %{agent_id: agent.id},
          actor: user
        )
        |> Ash.run_action()

      assert row.file_id == file.id
      assert row.token_count == 350
      assert row.file_status == "pending"
    end

    test "token_count is 0 when the file has no chunks", %{
      user: user,
      agent: agent,
      doc_file: file
    } do
      {:ok, _att} =
        Magus.Agents.create_attachment(
          %{custom_agent_id: agent.id, file_id: file.id, mode: :search},
          actor: user
        )

      {:ok, [row]} =
        Ash.ActionInput.for_action(
          Magus.Agents.CustomAgent,
          :agent_attachments,
          %{agent_id: agent.id},
          actor: user
        )
        |> Ash.run_action()

      assert row.token_count == 0
      assert row.file_status == "pending"
    end
  end
end
