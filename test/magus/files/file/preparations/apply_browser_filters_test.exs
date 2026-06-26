defmodule Magus.Files.File.Preparations.ApplyBrowserFiltersTest do
  use Magus.ResourceCase, async: true

  alias Magus.Files

  defp browser_query(args, actor) do
    Magus.Files.File
    |> Ash.Query.for_read(:personal_library_files, args, actor: actor)
  end

  # Minimal valid PNG file (1x1 transparent pixel) — used as bytes for any
  # file content in these tests. The browser filter prep does not inspect
  # bytes; it only filters by columns.
  @png_content <<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A>>

  defp make_file(user, attrs) do
    unique = System.unique_integer([:positive])
    type = Map.get(attrs, :type, :text)

    base = %{
      name: Map.get(attrs, :name, "f-#{unique}.txt"),
      type: type,
      mime_type: Map.get(attrs, :mime_type, default_mime(type)),
      file_size: byte_size(@png_content),
      file_path: "fbtest/#{user.id}/#{unique}-#{Ash.UUIDv7.generate()}"
    }

    Magus.Files.File
    |> Ash.Changeset.for_create(:create, Map.merge(base, Map.drop(attrs, [:source])), actor: user)
    |> maybe_force_source(attrs)
    |> Ash.create!(authorize?: false)
  end

  defp maybe_force_source(changeset, %{source: source}) when not is_nil(source) do
    Ash.Changeset.force_change_attribute(changeset, :source, source)
  end

  defp maybe_force_source(changeset, _), do: changeset

  defp default_mime(:image), do: "image/png"
  defp default_mime(:video), do: "video/mp4"
  defp default_mime(:document), do: "application/pdf"
  defp default_mime(:text), do: "text/plain"
  defp default_mime(:email), do: "message/rfc822"

  # Bypass timestamps macro — push updated_at + inserted_at into the past.
  defp set_updated_at!(file, dt) do
    require Ecto.Query

    {1, _} =
      Magus.Repo.update_all(
        Ecto.Query.from(f in "files", where: f.id == ^Ecto.UUID.dump!(file.id)),
        set: [updated_at: dt, inserted_at: dt]
      )

    file
  end

  describe "browser_type filter" do
    setup do
      user = generate(user())
      ensure_workspace_plan(user)
      img = make_file(user, %{type: :image, name: "i.png"})
      vid = make_file(user, %{type: :video, name: "v.mp4"})
      doc = make_file(user, %{type: :document, mime_type: "application/pdf", name: "d.pdf"})
      txt = make_file(user, %{type: :text, name: "t.txt"})
      %{user: user, img: img, vid: vid, doc: doc, txt: txt}
    end

    test "type=image returns only images", %{user: user, img: img} do
      results =
        Files.list_personal_library_files!(
          actor: user,
          query: browser_query(%{browser_type: "image"}, user)
        )
        |> Enum.map(& &1.id)

      assert results == [img.id]
    end

    test "type=pdf returns rows where mime_type = application/pdf", %{user: user, doc: doc} do
      results =
        Files.list_personal_library_files!(
          actor: user,
          query: browser_query(%{browser_type: "pdf"}, user)
        )
        |> Enum.map(& &1.id)

      assert results == [doc.id]
    end
  end

  describe "browser_modified filter" do
    test "modified=today excludes older files" do
      user = generate(user())
      ensure_workspace_plan(user)
      old = DateTime.add(DateTime.utc_now(), -10, :day)
      stale = make_file(user, %{name: "stale"})
      _ = set_updated_at!(stale, old)
      fresh = make_file(user, %{name: "fresh"})

      ids =
        Files.list_personal_library_files!(
          actor: user,
          query: browser_query(%{browser_modified: "today"}, user)
        )
        |> Enum.map(& &1.id)

      assert ids == [fresh.id]
    end
  end

  describe "browser_source filter" do
    test "source=uploaded includes only :user source" do
      user = generate(user())
      ensure_workspace_plan(user)
      uploaded = make_file(user, %{source: :user, name: "up"})
      _agent = make_file(user, %{source: :agent, name: "ag"})

      ids =
        Files.list_personal_library_files!(
          actor: user,
          query: browser_query(%{browser_source: "uploaded"}, user)
        )
        |> Enum.map(& &1.id)

      assert ids == [uploaded.id]
    end
  end
end
