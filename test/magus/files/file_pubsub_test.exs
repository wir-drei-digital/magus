defmodule Magus.Files.FilePubsubTest do
  use Magus.ResourceCase, async: false

  alias Magus.Files

  # Topic format: workspaces:{workspace_id}:files
  # Matches Prompt ("workspaces:{id}:prompts") and CustomAgent ("workspaces:{id}:agents")
  # conventions. Emitted via BroadcastWorkspaceEvent change using MagusWeb.Endpoint.broadcast/3
  # which wraps broadcasts in Phoenix.Socket.Broadcast for consistency with Ash notifier shape.

  describe "workspace pub_sub" do
    test "broadcasts on create when file has workspace_id" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "ws-file-pubsub-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      MagusWeb.Endpoint.subscribe("workspaces:#{workspace.id}:files")

      {:ok, file} =
        Files.create_file(
          %{
            name: "test.txt",
            type: :text,
            mime_type: "text/plain",
            file_size: 10,
            file_path: "/tmp/test-#{System.unique_integer([:positive])}.txt",
            workspace_id: workspace.id
          },
          actor: owner
        )

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: event,
        payload: %{id: id, workspace_id: ws_id, action: :created}
      }

      assert topic == "workspaces:#{workspace.id}:files"
      assert event == "create"
      assert id == file.id
      assert ws_id == workspace.id
    end

    test "broadcasts on destroy when file has workspace_id" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "ws-file-pubsub-del-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      {:ok, file} =
        Files.create_file(
          %{
            name: "deletable.txt",
            type: :text,
            mime_type: "text/plain",
            file_size: 10,
            file_path: "/tmp/test-#{System.unique_integer([:positive])}.txt",
            workspace_id: workspace.id
          },
          actor: owner
        )

      MagusWeb.Endpoint.subscribe("workspaces:#{workspace.id}:files")

      :ok = Files.delete_file(file, actor: owner)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        event: event,
        payload: %{id: id, workspace_id: ws_id, action: :deleted}
      }

      assert topic == "workspaces:#{workspace.id}:files"
      assert event == "destroy"
      assert id == file.id
      assert ws_id == workspace.id
    end

    test "does not broadcast workspace event for a file without workspace_id" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "ws-file-pubsub-nil-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      MagusWeb.Endpoint.subscribe("workspaces:#{workspace.id}:files")

      {:ok, _file} =
        Files.create_file(
          %{
            name: "no-workspace.txt",
            type: :text,
            mime_type: "text/plain",
            file_size: 10,
            file_path: "/tmp/test-#{System.unique_integer([:positive])}.txt"
          },
          actor: owner
        )

      refute_receive %Phoenix.Socket.Broadcast{}, 200
    end
  end
end
