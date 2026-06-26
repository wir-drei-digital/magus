defmodule Magus.Library.PromptPubsubTest do
  use Magus.ResourceCase, async: false

  describe "workspace pub_sub" do
    test "broadcasts on create when prompt has workspace_id" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "ws-pubsub-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      MagusWeb.Endpoint.subscribe("workspaces:#{workspace.id}:prompts")

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{name: "P", content: "B", type: :user, workspace_id: workspace.id},
          actor: owner
        )

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        payload: %{id: id, workspace_id: ws_id, action: :created}
      }

      assert topic == "workspaces:#{workspace.id}:prompts"
      assert id == prompt.id
      assert ws_id == workspace.id
    end

    test "broadcasts on update when prompt has workspace_id" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "ws-pubsub-upd-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{name: "P", content: "B", type: :user, workspace_id: workspace.id},
          actor: owner
        )

      MagusWeb.Endpoint.subscribe("workspaces:#{workspace.id}:prompts")

      {:ok, _updated} =
        Magus.Library.update_prompt(prompt, %{name: "P Updated"}, actor: owner)

      assert_receive %Phoenix.Socket.Broadcast{
        topic: topic,
        payload: %{id: id, workspace_id: ws_id, action: :updated}
      }

      assert topic == "workspaces:#{workspace.id}:prompts"
      assert id == prompt.id
      assert ws_id == workspace.id
    end

    test "does not broadcast to workspace topic when prompt has no workspace_id" do
      owner = generate(user())
      ensure_workspace_plan(owner)

      {:ok, workspace} =
        Magus.Workspaces.create_workspace(
          %{name: "T", slug: "ws-pubsub-nil-#{System.unique_integer([:positive])}"},
          actor: owner
        )

      MagusWeb.Endpoint.subscribe("workspaces:#{workspace.id}:prompts")

      {:ok, _prompt} =
        Magus.Library.create_prompt(
          %{name: "P", content: "B", type: :user},
          actor: owner
        )

      refute_receive %Phoenix.Socket.Broadcast{}, 200
    end
  end
end
