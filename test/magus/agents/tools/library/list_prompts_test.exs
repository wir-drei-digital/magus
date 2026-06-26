defmodule Magus.Agents.Tools.Library.ListPromptsTest do
  use Magus.ResourceCase, async: true

  alias Magus.Agents.Tools.Library.ListPrompts
  alias Magus.Library
  alias Magus.Workspaces

  defp create_prompt!(user, attrs) do
    {:ok, prompt} = Library.create_prompt(attrs, actor: user)
    prompt
  end

  defp setup_workspace do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, workspace} =
      Workspaces.create_workspace(
        %{name: "Prompts WS", slug: "prompts-ws-#{System.unique_integer([:positive])}"},
        actor: user
      )

    %{user: user, workspace: workspace}
  end

  defp run(user, context_overrides \\ %{}, params \\ %{}) do
    context = Map.merge(%{user_id: user.id}, context_overrides)
    ListPrompts.run(params, context)
  end

  describe "run/2 — personal scope" do
    test "returns personal prompts and ignores workspace prompts" do
      %{user: user, workspace: workspace} = setup_workspace()

      personal = create_prompt!(user, %{name: "Personal", content: "P", type: :user})

      _ws_prompt =
        create_prompt!(user, %{
          name: "WS",
          content: "W",
          type: :user,
          workspace_id: workspace.id
        })

      assert {:ok, %{prompts: prompts, count: count}} = run(user)
      assert count == 1
      assert [%{id: id}] = prompts
      assert id == personal.id
    end

    test "filters personal prompts by type" do
      %{user: user} = setup_workspace()

      _user_type = create_prompt!(user, %{name: "U", content: "u", type: :user})
      system_type = create_prompt!(user, %{name: "S", content: "s", type: :system})

      assert {:ok, %{prompts: [%{id: id, type: "system"}], count: 1}} =
               run(user, %{}, %{"type" => "system"})

      assert id == system_type.id
    end
  end

  describe "run/2 — workspace scope" do
    test "returns workspace prompts and ignores personal prompts" do
      %{user: user, workspace: workspace} = setup_workspace()

      _personal = create_prompt!(user, %{name: "Personal", content: "P", type: :user})

      ws_prompt =
        create_prompt!(user, %{
          name: "WS",
          content: "W",
          type: :user,
          workspace_id: workspace.id
        })

      assert {:ok, %{prompts: prompts, count: 1}} =
               run(user, %{workspace_id: workspace.id})

      assert [%{id: id}] = prompts
      assert id == ws_prompt.id
    end

    test "filters workspace prompts by type (SQL pushdown)" do
      %{user: user, workspace: workspace} = setup_workspace()

      _user_in_ws =
        create_prompt!(user, %{
          name: "U-WS",
          content: "u",
          type: :user,
          workspace_id: workspace.id
        })

      system_in_ws =
        create_prompt!(user, %{
          name: "S-WS",
          content: "s",
          type: :system,
          workspace_id: workspace.id
        })

      # Also create a system prompt in a DIFFERENT workspace to confirm
      # the workspace argument actually narrows results.
      {:ok, other_ws} =
        Workspaces.create_workspace(
          %{name: "Other", slug: "other-#{System.unique_integer([:positive])}"},
          actor: user
        )

      _system_other_ws =
        create_prompt!(user, %{
          name: "S-Other",
          content: "s",
          type: :system,
          workspace_id: other_ws.id
        })

      assert {:ok, %{prompts: [%{id: id, type: "system"}], count: 1}} =
               run(user, %{workspace_id: workspace.id}, %{"type" => "system"})

      assert id == system_in_ws.id
    end

    test "returns empty list when workspace has no prompts of that type" do
      %{user: user, workspace: workspace} = setup_workspace()

      _user_type =
        create_prompt!(user, %{
          name: "U-WS",
          content: "u",
          type: :user,
          workspace_id: workspace.id
        })

      assert {:ok, %{prompts: [], count: 0}} =
               run(user, %{workspace_id: workspace.id}, %{"type" => "system"})
    end
  end
end
