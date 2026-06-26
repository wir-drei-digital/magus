defmodule MagusWeb.Workbench.Resources.FileBrowserView.DataTest do
  use Magus.ResourceCase, async: true

  alias MagusWeb.Workbench.Resources.FileBrowserView.{Data, Entry}

  defp make_file(actor, attrs) do
    unique = System.unique_integer([:positive])

    base = %{
      name: Map.get(attrs, :name, "f-#{unique}.txt"),
      type: Map.get(attrs, :type, :text),
      mime_type: Map.get(attrs, :mime_type, "text/plain"),
      file_size: 1,
      file_path: "fbtest/#{unique}-#{Ash.UUIDv7.generate()}"
    }

    Magus.Files.File
    |> Ash.Changeset.for_create(:create, Map.merge(base, attrs), actor: actor)
    |> Ash.create!(authorize?: false)
  end

  describe "load/1" do
    test "my_files scope returns root folders + unfiled files" do
      user = generate(user())
      ensure_workspace_plan(user)
      root = generate(folder(actor: user, name: "Root"))

      _nested =
        Magus.Chat.create_folder!(%{name: "Nested", parent_id: root.id}, actor: user)

      free = make_file(user, %{name: "free.txt"})
      _filed = make_file(user, %{name: "filed.txt", folder_id: root.id})

      %{entries: entries, breadcrumbs: bc} =
        Data.load(%{
          scope: "my_files",
          id: nil,
          user: user,
          workspace_id: nil,
          filters: %{},
          sort: "updated_at:desc",
          q: ""
        })

      assert Enum.all?(entries, &match?(%Entry{}, &1))

      kinds = Enum.map(entries, & &1.kind) |> Enum.uniq()
      assert :folder in kinds
      assert :file in kinds

      ids = Enum.map(entries, & &1.id)
      assert root.id in ids
      assert free.id in ids

      assert bc == [%{label: "My Files", path: "/files"}]
    end

    test "folder scope walks ancestors for breadcrumb" do
      user = generate(user())
      a = generate(folder(actor: user, name: "A"))

      b =
        Magus.Chat.create_folder!(%{name: "B", parent_id: a.id}, actor: user)

      c =
        Magus.Chat.create_folder!(%{name: "C", parent_id: b.id}, actor: user)

      %{breadcrumbs: bc} =
        Data.load(%{
          scope: "folder",
          id: c.id,
          user: user,
          workspace_id: nil,
          filters: %{},
          sort: "updated_at:desc",
          q: ""
        })

      labels = Enum.map(bc, & &1.label)
      assert labels == ["My Files", "A", "B", "C"]
    end

    test "search query filters entries by name" do
      user = generate(user())
      ensure_workspace_plan(user)
      _hit = make_file(user, %{name: "cover-final.png", type: :image, mime_type: "image/png"})

      _miss =
        make_file(user, %{name: "report.pdf", type: :document, mime_type: "application/pdf"})

      %{entries: entries} =
        Data.load(%{
          scope: "my_files",
          id: nil,
          user: user,
          workspace_id: nil,
          filters: %{},
          sort: "updated_at:desc",
          q: "cover"
        })

      names = Enum.map(entries, & &1.name)
      assert "cover-final.png" in names
      refute "report.pdf" in names
    end
  end
end
