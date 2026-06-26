defmodule Magus.Agents.Tools.Files.ListWorkspaceTemplatesTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  alias Magus.Agents.Tools.Files.ListWorkspaceTemplates

  setup do
    user = generate(user())
    ensure_workspace_plan(user)

    {:ok, _regular} =
      Magus.Files.create_file(
        %{
          name: "regular.pdf",
          type: :document,
          mime_type: "application/pdf",
          file_size: 10,
          file_path: "tmp/r.pdf"
        },
        actor: user
      )

    {:ok, tmpl} =
      Magus.Files.create_file(
        %{
          name: "ContractTemplate.docx",
          type: :document,
          mime_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
          file_size: 4096,
          file_path: "tmp/c.docx",
          is_template: true
        },
        actor: user
      )

    %{user: user, tmpl: tmpl}
  end

  test "returns templates accessible to the user", %{user: user, tmpl: tmpl} do
    {:ok, %{templates: list}} =
      ListWorkspaceTemplates.run(%{}, %{
        user_id: user.id,
        conversation_id: Ecto.UUID.generate()
      })

    assert Enum.any?(list, &(&1.id == tmpl.id))
    refute Enum.any?(list, fn t -> Map.get(t, :is_template) == false end)

    sample = Enum.find(list, &(&1.id == tmpl.id))
    assert sample.name == "ContractTemplate.docx"
    assert sample.mime_type =~ "wordprocessing"
  end

  test "filters by query", %{user: user, tmpl: tmpl} do
    {:ok, %{templates: list}} =
      ListWorkspaceTemplates.run(%{"query" => "Contract"}, %{
        user_id: user.id,
        conversation_id: Ecto.UUID.generate()
      })

    assert Enum.map(list, & &1.id) == [tmpl.id]
  end

  test "summarize_output renders count" do
    assert ListWorkspaceTemplates.summarize_output(%{templates: [%{}, %{}]}) =~ "2"
  end
end
