defmodule MagusWeb.Workbench.Modes.PromptsModeNav.DataTest do
  use Magus.ResourceCase, async: true

  alias MagusWeb.Workbench.Modes.PromptsModeNav.Data
  alias MagusWeb.Workbench.Layout.ResourceTree.Section

  describe "load_sections/1 in personal mode" do
    test "returns a personal section with prompts as leaf nodes" do
      user = generate(user())

      {:ok, prompt} =
        Magus.Library.create_prompt(
          %{name: "Greet", content: "Hello", type: :user},
          actor: user
        )

      sections =
        Data.load_sections(%{
          user: user,
          workspace_id: nil,
          search_query: "",
          tree_target: nil
        })

      [%Section{key: :personal, nodes: nodes}] = sections
      assert Enum.any?(nodes, &(&1.id == prompt.id and &1.kind == :leaf))
      assert Enum.all?(nodes, &(&1.icon == "lucide-scroll-text"))
    end
  end
end
