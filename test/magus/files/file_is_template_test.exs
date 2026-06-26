defmodule Magus.Files.FileIsTemplateTest do
  use Magus.DataCase, async: true

  import Magus.Generators

  setup do
    user = generate(user())
    ensure_workspace_plan(user)
    %{user: user}
  end

  describe "is_template" do
    test "defaults to false", %{user: user} do
      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "doc.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1,
            file_path: "tmp/doc.pdf"
          },
          actor: user
        )

      refute file.is_template
    end

    test "can be set to true on create", %{user: user} do
      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "tmpl.docx",
            type: :document,
            mime_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            file_size: 1,
            file_path: "tmp/tmpl.docx",
            is_template: true
          },
          actor: user
        )

      assert file.is_template
    end

    test "can be toggled on update", %{user: user} do
      {:ok, file} =
        Magus.Files.create_file(
          %{
            name: "x.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1,
            file_path: "tmp/x.pdf"
          },
          actor: user
        )

      {:ok, updated} = Magus.Files.update_file(file, %{is_template: true}, actor: user)
      assert updated.is_template
    end
  end

  describe "list_templates" do
    setup %{user: user} do
      workspace = generate(workspace(actor: user))

      {:ok, _} =
        Magus.Files.create_file(
          %{
            name: "regular.pdf",
            type: :document,
            mime_type: "application/pdf",
            file_size: 1,
            file_path: "tmp/r.pdf",
            workspace_id: workspace.id
          },
          actor: user
        )

      {:ok, tmpl1} =
        Magus.Files.create_file(
          %{
            name: "Quarter.docx",
            type: :document,
            mime_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            file_size: 1,
            file_path: "tmp/q.docx",
            workspace_id: workspace.id,
            is_template: true
          },
          actor: user
        )

      {:ok, tmpl2} =
        Magus.Files.create_file(
          %{
            name: "Personal.docx",
            type: :document,
            mime_type: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            file_size: 1,
            file_path: "tmp/p.docx",
            is_template: true
          },
          actor: user
        )

      %{workspace: workspace, tmpl1: tmpl1, tmpl2: tmpl2}
    end

    test "returns only templates", %{user: user, tmpl1: tmpl1, tmpl2: tmpl2} do
      {:ok, list} = Magus.Files.list_templates(actor: user)
      ids = list |> Enum.map(& &1.id) |> Enum.sort()
      assert ids == Enum.sort([tmpl1.id, tmpl2.id])
    end

    test "filters by name substring (case-insensitive)", %{user: user, tmpl1: tmpl1} do
      {:ok, list} = Magus.Files.list_templates(%{query: "quart"}, actor: user)
      assert Enum.map(list, & &1.id) == [tmpl1.id]
    end
  end
end
